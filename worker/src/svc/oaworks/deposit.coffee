
# need listing of deposits and deposited for each user ID
# and/or given a uid, find the most recent URL that this users uid submitted a deposit for
# need to handle old/new user configs somehow - just store all the old ones and let the UI pick them up
# make sure all users submit the config with the incoming query (for those that still don't, temporarily copy them from old imported ones)

# NOTE to receive files cloudflare should be setup to DNS route this directly to backend, and any calls to it should call that dns subdomain
# because otherwise cloudflare will limit file upload size (100mb by default, and enterprise plans required for more)
# however also busboy is required, so needs to be a direct call to backend

P.svc.oaworks.deposits = _index: true # store a record of all deposits

P.svc.oaworks.deposit = (params, file, dev) ->
  params ?= @copy @params
  file ?= @request.files[0] if @request.files # TODO check where these will end up - will they only work on bg with busboy?
  file = file[0] if Array.isArray file
  dev ?= @S.dev

  dep = {}
  dep[k] = params[k] for k in ['embedded', 'demo', 'pilot', 'live', 'email', 'plugin']
  dep.pilot = Date.now() if dep.pilot
  dep.live = Date.now() if dep.live is true
  dep.name = file?.filename ? file?.name
  dep.from = params.from if params.from isnt 'anonymous'
  # if confirmed is true the submitter has confirmed this is the right file (and decode saves it as a "true" string, not bool, so doesn't clash in ES). If confirmed is the checksum this is a resubmit by an admin
  dep.confirmed = decodeURIComponent(params.confirmed) if params.confirmed
  dep.doi = params.doi ? params.metadata?.doi

  params.metadata = await @svc.oaworks.metadata(params.doi) if not params.metadata? and params.doi

  uc = params.config # should exist but may not
  uc = JSON.parse(params.config) if typeof params.config is 'string'
  if not params.config and params.from
    uc = await @fetch 'https://' + (if dev then 'dev.' else '') + 'api.cottagelabs.com/service/oab/deposit/config?uid=' + params.from

  perms = await @svc.oaworks.permissions params.metadata ? params.doi # SYP only works on DOI so far, so deposit only works if permissions can work, which requires a DOI if about a specific article
  arch = await @svc.oaworks.archivable file, undefined, (if dep.confirmed and dep.confirmed isnt true then dep.confirmed else undefined), params.metadata
  if arch?.archivable and (not dep.confirmed or dep.confirmed is arch.checksum) # if the depositor confirms we don't deposit, we manually review - only deposit on admin confirmation (but on dev allow it)
    zn = content: file.data, name: arch.name
    zn.publish = @S.svc.oaworks?.deposit?.zenodo is true
    creators = []
    for a in params.metadata?.author ? []
      if a.family?
        at = {name: a.family + (if a.given then ', ' + a.given else '')}
        try at.orcid = a.ORCID.split('/').pop() if a.ORCID
        try at.affiliation = a.affiliation.name if typeof a.affiliation is 'object' and a.affiliation.name?
        creators.push at 
    creators = [{name:'Unknown'}] if creators.length is 0
    description = if params.metadata.abstract then params.metadata.abstract + '<br><br>' else ''
    description += perms.best_permission?.deposit_statement ? (if params.metadata.doi? then 'The publisher\'s final version of this work can be found at https://doi.org/' + d.metadata.doi else '')
    description = description.trim()
    description += '.' if description.lastIndexOf('.') isnt description.length-1
    description += ' ' if description.length
    description += '<br><br>Deposited by shareyourpaper.org and openaccessbutton.org. We\'ve taken reasonable steps to ensure this content doesn\'t violate copyright. However, if you think it does you can request a takedown by emailing help@openaccessbutton.org.'
    meta =
      title: params.metadata.title ? 'Unknown',
      description: description.trim(),
      creators: creators,
      version: if arch.version is 'preprint' then 'Submitted Version' else if arch.version is 'postprint' then 'Accepted Version' else if arch.version is 'publisher pdf' then 'Published Version' else 'Accepted Version',
      journal_title: params.metadata.journal
      journal_volume: params.metadata.volume
      journal_issue: params.metadata.issue
      journal_pages: params.metadata.page
    if params.doi
      in_zenodo = await @src.zenodo.records.doi params.doi
      if in_zenodo and dep.confirmed isnt arch.checksum and not dev
        dep.zenodo = already: in_zenodo.id # we don't put it in again although we could with doi as related field - but leave for review for now
      else
        meta['related_identifiers'] = [{relation: (if meta.version is 'postprint' or meta.version is 'AAM' or meta.version is 'preprint' then 'isPreviousVersionOf' else 'isIdenticalTo'), identifier: params.doi}]
    meta.prereserve_doi = true
    meta['access_right'] = 'open'
    meta.license = perms.best_permission?.licence ? 'cc-by' # zenodo also accepts other-closed and other-nc, possibly more
    meta.license = 'other-closed' if meta.license.indexOf('other') isnt -1 and meta.license.indexOf('closed') isnt -1
    meta.license = 'other-nc' if meta.license.indexOf('other') isnt -1 and meta.license.indexOf('non') isnt -1 and meta.license.indexOf('commercial') isnt -1
    meta.license += '-4.0' if meta.license.toLowerCase().indexOf('cc') is 0 and isNaN(parseInt(meta.license.substring(meta.license.length-1)))
    try
      if perms.best_permission?.embargo_end and moment(perms.best_permission.embargo_end,'YYYY-MM-DD').valueOf() > Date.now()
        meta['access_right'] = 'embargoed'
        meta['embargo_date'] = perms.best_permission.embargo_end # check date format required by zenodo
        dep.embargo = perms.best_permission.embargo_end
    try meta['publication_date'] = params.metadata.published if params.metadata.published? and typeof params.metadata.published is 'string'
    if uc
      uc.community = uc.community_ID if uc.community_ID? and not uc.community?
      if uc.community
        uc.communities ?= []
        uc.communities.push({identifier: ccm}) for ccm in (if typeof uc.community is 'string' then uc.community.split(',') else uc.community)
      if uc.community? or uc.communities?
        uc.communities ?= uc.community
        uc.communities = [uc.communities] if not Array.isArray uc.communities
        meta['communities'] = []
        meta.communities.push(if typeof com is 'string' then {identifier: com} else com) for com in uc.communities
    if tk = (if dev or dep.demo then @S.svc.oaworks?.zenodo?.sandbox else @S.svc.oaworks?.zenodo?.token)
      if not dep.zenodo?.already
        z = await @src.zenodo.deposition.create meta, zn, tk
        if z.id
          dep.zenodo = 
            id: z.id
            url: 'https://' + (if dev or dep.demo then 'sandbox.' else '') + 'zenodo.org/record/' + z.id
            doi: z.metadata.prereserve_doi.doi if z.metadata?.prereserve_doi?.doi?
            file: z.uploaded?.links?.download ? z.uploaded?.links?.download
          dep.doi ?= dep.zenodo.doi
          dep.type = 'zenodo'
        else
          dep.error = 'Deposit to Zenodo failed'
          try dep.error += ': ' + JSON.stringify z
          dep.type = 'review'
    else
      dep.error = 'No Zenodo credentials available'
      dep.type = 'review'
  dep.version = arch?.version
  if not dep.type and params.from and (not dep.embedded or (dep.embedded.indexOf('oa.works') is -1 and dep.embedded.indexOf('openaccessbutton.org') is -1 and dep.embedded.indexOf('shareyourpaper.org') is -1))
    dep.type = if params.redeposit then 'redeposit' else if file then 'forward' else 'dark'

  if dep.doi and not dep.error
    dep.type ?= 'review'
    dep.url = if typeof params.redeposit is 'string' then params.redeposit else if params.url then params.url else undefined

    if not exists = await @svc.oaworks.deposits 'doi:"' + dep.doi + '"' + (if dep.from then ' AND from:"' + dep.from + '"' else '')
      dep.createdAt = Date.now()
      @waitUntil @svc.oaworks.deposits dep
    else
      improved = false
      if dep.name and not exists.name
        improved = true
        exists.name = dep.name
      if dep.confirmed and (not exists.confirmed or (exists.confirmed is 'true' and dep.confirmed isnt 'true'))
        improved = true
        exists.confirmed = dep.confirmed
      exists.type = [exists.type] if typeof exists.type is 'string'
      if dep.type not in exists.type
        improved = true
        exists.type.push dep.type
      if dep.zenodo? and not dep.zenodo.already? and not exists.zenodo
        improved = true
        exists.zenodo = dep.zenodo
      if improved
        exists.updatedAt = Date.now()
        exists.duplicate ?= 0
        exists.duplicate += 1
        @waitUntil @svc.oaworks.deposits exists
      dep.duplicate = exists.duplicate ? 1

    if (dep.type isnt 'review' or file?) and arch?.archivable isnt false and not dep.duplicate # so when true or when undefined if no file is given
      bcc = ['joe@oa.works']
      tos = []
      if typeof uc?.owner is 'string' and uc.owner.indexOf('@') isnt -1
        tos.push uc.owner
      else if uc.email
        tos.push uc.email
      if tos.length is 0
        tos = @copy bcc
        bcc = []
    
      ed = @copy dep
      ed.metadata = params.metadata ? {}
      as = []
      for author in (ed.metadata.author ? [])
        if author.family
          as.push (if author.given then author.given + ' ' else '') + author.family
      ed.metadata.author = as
      ed.adminlink = (if ed.embedded then ed.embedded else 'https://shareyourpaper.org' + (if ed.metadata.doi then '/' + ed.metadata.doi else ''))
      ed.adminlink += if ed.adminlink.includes('?') then '&' else '?'
      if arch?.checksum?
        ed.confirmed = encodeURIComponent arch.checksum
        ed.adminlink += 'confirmed=' + ed.confirmed + '&'
      ed.adminlink += 'email=' + ed.email
      tmpl = await @svc.oaworks.templates dep.type + '_deposit.html'
      tmpl = tmpl.content

      ml =
        from: 'deposits@oa.works'
        to: tos
        template: tmpl
        vars: ed
        subject: (sub.subject ? dep.type + ' deposit')
        html: sub.content
      ml.bcc = bcc if bcc and bcc.length # passing undefined to mail seems to cause errors, so only set if definitely exists
      ml.attachments = [{filename: (file.filename ? file.name), content: file.data}] if file
      @waitUntil @mail ml

  return dep

P.svc.oaworks.deposit._bg = true



P.svc.oaworks.archivable = (file, url, confirmed, meta={}) ->
  file ?= @request.files[0] if @request.files # TODO check where these will end up - will they only work on bg with busboy?
  file = file[0] if Array.isArray file

  f = {archivable: undefined, archivable_reason: undefined, version: 'unknown', same_paper: undefined, licence: undefined}

  # handle different sorts of file passing
  if typeof file is 'string'
    file = data: file
  if not file? and url?
    file = await @fetch url # check if this gets file content

  if file?
    file.name ?= file.filename
    try f.name = file.name
    try f.format = if file.name? and file.name.includes('.') then file.name.split('.').pop() else 'html'
    if file.data
      if f.format is 'pdf'
        try content = await @convert.pdf2txt file.data
      if not content? and f.format? and @convert[f.format+'2txt']?
        try content = await @convert[f.format+'2txt'] file.data
      if not content?
        content = await @convert.file2txt file.data, {name: file.name}
      if not content?
        fd = file.data
        if typeof file.data isnt 'string'
          try fd = file.data.toString()
        try
          if fd.startsWith '<html'
            content = await @convert.html2txt fd
          else if file.data.startsWith '<xml'
            content = await @convert.xml2txt fd
      try content ?= file.data
      try content = content.toString()

  if not content? and not confirmed
    if file? or url?
      f.error = file.error ? 'Could not extract any content'
  else
    _clean = (str) -> return str.toLowerCase().replace(/[^a-z0-9\/\.]+/g, "").replace(/\s\s+/g, ' ').trim()

    contentsmall = if content.length < 20000 then content else content.substring(0,6000) + content.substring(content.length-6000,content.length)
    lowercontentsmall = contentsmall.toLowerCase()
    lowercontentstart = _clean(if lowercontentsmall.length < 6000 then lowercontentsmall else lowercontentsmall.substring(0,6000))

    f.name ?= meta.title
    try f.checksum = crypto.createHash('md5').update(content, 'utf8').digest('base64')
    f.same_paper_evidence = {} # check if the file meets our expectations
    try f.same_paper_evidence.words_count = content.split(' ').length # will need to be at least 500 words
    try f.same_paper_evidence.words_more_than_threshold = if f.same_paper_evidence.words_count > 500 then true else false
    try f.same_paper_evidence.doi_match = if meta.doi and lowercontentstart.indexOf(_clean meta.doi) isnt -1 then true else false # should have the doi in it near the front
    #if content and not f.same_paper_evidence.doi_match and not meta.title?
    #  meta = API.service.oab.metadata undefined, meta, content # get at least title again if not already tried to get it, and could not find doi in the file
    try f.same_paper_evidence.title_match = if meta.title and lowercontentstart.replace(/\./g,'').includes(_clean meta.title.replace(/ /g,'').replace(/\./g,'')) then true else false
    if meta.author?
      try
        authorsfound = 0
        f.same_paper_evidence.author_match = false
        # get the surnames out if possible, or author name strings, and find at least one in the doc if there are three or less, or find at least two otherwise
        meta.author = {name: meta.author} if typeof meta.author is 'string'
        meta.author = [meta.author] if not Array.isArray meta.author
        for a in meta.author
          if f.same_paper_evidence.author_match is true
            break
          else
            try
              an = (a.last ? a.lastname ? a.family ? a.surname ? a.name).trim().split(',')[0].split(' ')[0]
              af = (a.first ? a.firstname ? a.given ? a.name).trim().split(',')[0].split(' ')[0]
              inc = lowercontentstart.indexOf _clean an
              if an.length > 2 and af.length > 0 and inc isnt -1 and lowercontentstart.substring(inc-20, inc + an.length+20).includes _clean af
                authorsfound += 1
                if (meta.author.length < 3 and authorsfound is 1) or (meta.author.length > 2 and authorsfound > 1)
                  f.same_paper_evidence.author_match = true
                  break
    if f.format?
      for ft in ['doc','tex','pdf','htm','xml','txt','rtf','odf','odt','page']
        if f.format.indexOf(ft) isnt -1
          f.same_paper_evidence.document_format = true
          break

    f.same_paper = if f.same_paper_evidence.words_more_than_threshold and (f.same_paper_evidence.doi_match or f.same_paper_evidence.title_match or f.same_paper_evidence.author_match) and f.same_paper_evidence.document_format then true else false

    if f.same_paper_evidence.words_count < 150 and f.format is 'pdf'
      # there was likely a pdf file reading failure due to bad PDF formatting
      f.same_paper_evidence.words_count = 0
      f.archivable_reason = 'We could not find any text in the provided PDF. It is possible the PDF is a scan in which case text is only contained within images which we do not yet extract. Or, the PDF may have errors in it\'s structure which stops us being able to machine-read it'

    f.version_evidence = score: 0, strings_checked: 0, strings_matched: []
    try
      # dev https://docs.google.com/spreadsheets/d/1XA29lqVPCJ2FQ6siLywahxBTLFaDCZKaN5qUeoTuApg/edit#gid=0
      # live https://docs.google.com/spreadsheets/d/10DNDmOG19shNnuw6cwtCpK-sBnexRCCtD4WnxJx_DPQ/edit#gid=0
      for l in await @src.google.sheets (if @S.dev then '1XA29lqVPCJ2FQ6siLywahxBTLFaDCZKaN5qUeoTuApg' else '10DNDmOG19shNnuw6cwtCpK-sBnexRCCtD4WnxJx_DPQ')
        try
          f.version_evidence.strings_checked += 1
          wts = l.whattosearch
          if wts.includes('<<') and wts.includes '>>'
            wtm = wts.split('<<')[1].split('>>')[0]
            wts = wts.replace('<<'+wtm+'>>', meta[wtm.toLowerCase()]) if meta[wtm.toLowerCase()]?
          matched = false
          if l.howtosearch is 'string'
            matched = if (l.wheretosearch is 'file' and contentsmall.indexOf(wts) isnt -1) or (l.wheretosearch isnt 'file' and ((meta.title? and meta.title.indexOf(wts) isnt -1) or (f.name? and f.name.indexOf(wts) isnt -1))) then true else false
          else
            re = new RegExp wts, 'gium'
            matched = if (l.wheretosearch is 'file' and lowercontentsmall.match(re) isnt null) or (l.wheretosearch isnt 'file' and ((meta.title? and meta.title.match(re) isnt null) or (f.name? and f.name.match(re) isnt null))) then true else false
          if matched
            sc = l.score ? l.score_value
            if typeof sc is 'string'
              try sc = parseInt sc
            sc = 1 if typeof sc isnt 'number'
            if l.whatitindicates is 'publisher pdf' then f.version_evidence.score += sc else f.version_evidence.score -= sc
            f.version_evidence.strings_matched.push {indicates: l.whatitindicates, found: l.howtosearch + ' ' + wts, in: l.wheretosearch, score_value: sc}

    f.version = 'publishedVersion' if f.version_evidence.score > 0
    f.version = 'acceptedVersion' if f.version_evidence.score < 0
    if f.version is 'unknown' and f.version_evidence.strings_checked > 0 #and f.format? and f.format isnt 'pdf'
      f.version = 'acceptedVersion'

    try
      ls = await @svc.lantern.licence undefined, undefined, lowercontentsmall # check lantern for licence info in the file content
      if ls?.licence?
        f.licence = ls.licence
        f.licence_evidence = {string_match: ls.match}
      f.lantern = ls

    f.archivable = false
    if confirmed
      f.archivable = true
      if confirmed is f.checksum
        f.archivable_reason = 'The administrator has confirmed that this file is a version that can be archived.'
        f.admin_confirms = true
      else
        f.archivable_reason = 'The depositor says that this file is a version that can be archived'
        f.depositor_says = true
    else if f.same_paper
      if f.format isnt 'pdf'
        f.archivable = true
        f.archivable_reason = 'Since the file is not a PDF, we assume it is a Postprint.'
      if not f.archivable and f.licence? and f.licence.toLowerCase().startsWith 'cc'
        f.archivable = true
        f.archivable_reason = 'It appears this file contains a ' + f.lantern.licence + ' licence statement. Under this licence the article can be archived'
      if not f.archivable
        if f.version is 'publishedVersion'
          f.archivable_reason = 'The file given is a Publisher PDF, and only postprints are allowed'
        else
          f.archivable_reason = 'We cannot confirm if it is an archivable version or not'
    else
      f.archivable_reason ?= if not f.same_paper_evidence.words_more_than_threshold then 'The file is less than 500 words, and so does not appear to be a full article' else if not f.same_paper_evidence.document_format then 'File is an unexpected format ' + f.format else if not meta.doi and not meta.title then 'We have insufficient metadata to validate file is for the correct paper ' else 'File does not contain expected metadata such as DOI or title'

  return f
