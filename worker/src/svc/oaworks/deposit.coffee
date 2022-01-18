
# need listing of deposits and deposited for each user ID
# and/or given a uid, find the most recent URL that this users uid submitted a deposit for
# need to handle old/new user configs somehow - just store all the old ones and let the UI pick them up
# make sure all users submit the config with the incoming query (for those that still don't, temporarily copy them from old imported ones)
# NOTE to receive files should send to background server
# cloudflare will limit file upload size (100mb by default, and enterprise plans required for more)

P.svc.oaworks.deposits = _index: true # store a record of all deposits

P.svc.oaworks.deposit = (params, file, dev) ->
  params ?= @copy @params
  params.doi = params.metadata.doi if params.metadata?.doi and not params.doi
  file ?= @request.files[0] if @request.files
  file = file[0] if Array.isArray file
  dev ?= @S.dev

  dep = createdAt: Date.now()
  dep.created_date = await @datetime dep.createdAt
  dep[k] = params[k] for k in ['embedded', 'demo', 'pilot', 'live', 'email', 'plugin']
  dep.pilot = Date.now() if dep.pilot is true
  dep.live = Date.now() if dep.live is true
  dep.name = file?.filename ? file?.name
  dep.from = params.from if params.from isnt 'anonymous'
  # if confirmed is true the submitter has confirmed this is the right file (and decode saves it as a "true" string, not bool, so doesn't clash in ES). If confirmed is the checksum this is a resubmit by an admin
  dep.confirmed = decodeURIComponent(params.confirmed) if params.confirmed
  dep.doi = params.doi ? params.metadata?.doi

  params.metadata = await @svc.oaworks.metadata(params.doi) if not params.metadata? and params.doi
  dep.metadata = params.metadata

  uc = params.config # should exist but may not
  uc = JSON.parse(params.config) if typeof params.config is 'string'
  if not params.config and params.from
    uc = await @fetch 'https://' + (if dev then 'dev.' else '') + 'api.cottagelabs.com/service/oab/deposit/config?uid=' + params.from

  dep.permissions = params.permissions ? await @svc.oaworks.permissions params.metadata ? params.doi # SYP only works on DOI so far, so deposit only works if permissions can work, which requires a DOI if about a specific article
  dep.archivable = await @svc.oaworks.archivable file, undefined, dep.confirmed, params.metadata, dep.permissions, dev
  delete dep.archivable.metadata if dep.archivable?.metadata?
  if dep.archivable?.archivable and (not dep.confirmed or dep.confirmed is dep.archivable.checksum) # if the depositor confirms we don't deposit, we manually review - only deposit on admin confirmation (but on dev allow it)
    zn = content: file.data, name: dep.archivable.name
    zn.publish = true
    creators = []
    for a in params.metadata?.author ? []
      if a.family?
        at = {name: a.family + (if a.given then ', ' + a.given else '')}
        try at.orcid = a.ORCID.split('/').pop() if a.ORCID
        try at.affiliation = a.affiliation.name if typeof a.affiliation is 'object' and a.affiliation.name?
        creators.push at 
    creators = [{name:'Unknown'}] if creators.length is 0

    description = if params.metadata.abstract then params.metadata.abstract + '<br><br>' else ''
    description += dep.permissions.best_permission?.deposit_statement ? (if params.metadata.doi? then 'The publisher\'s final version of this work can be found at https://doi.org/' + params.metadata.doi else '')
    description = description.trim()
    description += '.' if description.lastIndexOf('.') isnt description.length-1
    description += ' ' if description.length
    description += '<br><br>Deposited by shareyourpaper.org and openaccessbutton.org. We\'ve taken reasonable steps to ensure this content doesn\'t violate copyright. However, if you think it does you can request a takedown by emailing help@openaccessbutton.org.'

    meta =
      title: params.metadata.title ? 'Unknown',
      description: description.trim(),
      creators: creators,
      version: if dep.archivable.version is 'preprint' then 'Submitted Version' else if dep.archivable.version is 'postprint' then 'Accepted Version' else if dep.archivable.version is 'publisher pdf' then 'Published Version' else 'Accepted Version',
      journal_title: params.metadata.journal
      journal_volume: params.metadata.volume
      journal_issue: params.metadata.issue
      journal_pages: params.metadata.page

    if params.doi
      #in_zenodo = await @src.zenodo.records.doi params.doi, dev
      zs = await @src.zenodo.records.search '"' + params.doi + '"', dev
      if zs?.hits?.total
        in_zenodo = zs.hits.hits[0]
      if in_zenodo and dep.confirmed isnt dep.archivable.checksum and not dev
        dep.zenodo = already: in_zenodo.id
      else
        meta['related_identifiers'] = [{relation: (if meta.version is 'postprint' or meta.version is 'AAM' or meta.version is 'preprint' then 'isPreviousVersionOf' else 'isIdenticalTo'), identifier: params.doi}]
    meta.prereserve_doi = true
    meta['access_right'] = 'open'
    meta.license = dep.permissions.best_permission?.licence ? 'cc-by' # zenodo also accepts other-closed and other-nc, possibly more
    meta.license = 'other-closed' if meta.license.includes('other') and meta.license.includes 'closed'
    meta.license = 'other-nc' if meta.license.includes('other') and meta.license.includes('non') and meta.license.includes 'commercial'
    meta.license += '-4.0' if meta.license.toLowerCase().startsWith('cc') and isNaN(parseInt(meta.license.substring(meta.license.length-1)))
    try
      if dep.permissions.best_permission?.embargo_end
        ee = await @epoch dep.permissions.best_permission.embargo_end
        if ee > Date.now()
          meta['access_right'] = 'embargoed'
          meta['embargo_date'] = dep.permissions.best_permission.embargo_end # check date format required by zenodo
          dep.embargo = dep.permissions.best_permission.embargo_end
    try meta['publication_date'] = params.metadata.published if params.metadata.published? and typeof params.metadata.published is 'string'

    if uc?
      dep.config = uc
      uc.community = uc.community_ID if uc.community_ID? and not uc.community?
      if uc.community
        uc.communities ?= []
        uc.communities.push({identifier: ccm}) for ccm in (if typeof uc.community is 'string' then uc.community.split(',') else uc.community)
      if uc.community? or uc.communities?
        uc.communities ?= uc.community
        uc.communities = [uc.communities] if not Array.isArray uc.communities
        meta.communities = []
        meta.communities.push(if typeof com is 'string' then {identifier: com} else com) for com in uc.communities
      dep.community = meta.communities[0].identifier if meta.communities and meta.communities.length

    if tk = (if dev or dep.demo then @S.svc.oaworks?.zenodo?.sandbox else @S.svc.oaworks?.zenodo?.token)
      if not dep.zenodo?.already
        z = await @src.zenodo.deposition.create meta, zn, tk, dev
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

  dep.version = dep.archivable?.version
  if not dep.type and params.from and (not dep.embedded or (not dep.embedded.includes('oa.works') and not dep.embedded.includes('openaccessbutton.org') and not dep.embedded.includes('shareyourpaper.org')))
    dep.type = if params.redeposit then 'redeposit' else if file then 'forward' else 'dark'

  if dep.doi and not dep.error
    dep.type ?= 'review'
    dep.url = if typeof params.redeposit is 'string' then params.redeposit else if params.url then params.url else undefined

    await @svc.oaworks.deposits dep

    if (dep.type isnt 'review' or file?) and dep.archivable?.archivable isnt false and (not exists?.zenodo?.already or dev)
      bcc = ['joe@oa.works']
      bcc.push('mark@oa.works') if dev
      tos = []
      if typeof uc?.owner is 'string' and uc.owner.includes '@'
        tos.push uc.owner
      else if uc?.email
        tos.push uc.email
      if tos.length is 0
        tos = @copy bcc
        bcc = []
    
      as = []
      for author in (dep.metadata?.author ? [])
        if author.family
          as.push (if author.given then author.given + ' ' else '') + author.family
      dep.metadata.author = as
      dep.adminlink = (if dep.embedded then dep.embedded else 'https://shareyourpaper.org' + (if dep.metadata.doi then '/' + dep.metadata.doi else ''))
      dep.adminlink += if dep.adminlink.includes('?') then '&' else '?'
      if dep.archivable?.checksum?
        dep.confirmed = encodeURIComponent dep.archivable.checksum
        dep.adminlink += 'confirmed=' + dep.confirmed + '&'
      dep.adminlink += 'email=' + dep.email if dep.email not in dep.adminlink
      tmpl = await @svc.oaworks.templates dep.type + '_deposit'
      parts = await @template tmpl.content, dep
      delete dep.adminlink
      delete dep.confirmed

      ml =
        from: 'deposits@oa.works'
        to: tos
        subject: (parts.subject ? dep.type + ' deposit')
        html: parts.content
      ml.bcc = bcc if bcc and bcc.length # passing undefined to mail seems to cause errors, so only set if definitely exists
      ml.attachment = {file: file.data, filename: dep.archivable?.name ? file.name ? file.filename} if file
      await @mail ml

  # embargo_UI is a legacy value for old embeds, can be removed once we switch to new separate embed repo code
  if dep.embargo
    try dep.embargo_UI = (new Date(dep.embargo)).toLocaleString('en-GB', {year: 'numeric', month: 'long', day: 'numeric'}).replace(/(11|12|13) /, '$1th ').replace('1 ', '1st ').replace('2 ', '2nd ').replace('3 ', '3rd ').replace(/([0-9]) /, '$1th ')
  return dep

P.svc.oaworks.deposit._bg = true



P.svc.oaworks.archivable = (file, url, confirmed, meta, permissions, dev) ->
  dev ?= @S.dev
  file ?= @request.files[0] if @request.files
  file = file[0] if Array.isArray file

  f = {archivable: undefined, archivable_reason: undefined, version: 'unknown', same_paper: undefined, licence: undefined}

  if typeof meta is 'string' or (not meta? and (@params.doi or @params.title))
    meta = await @svc.oaworks.metadata meta ? @params.doi ? @params.title
  meta ?= {}

  # handle different sorts of file passing
  if typeof file is 'string'
    file = data: file
  if not file? and url?
    file = await @fetch url # check if this gets file content

  if file?
    file.name ?= file.filename
    try f.name = file.name
    try f.format = if file.name? and file.name.includes('.') then file.name.split('.').pop() else 'html'
    f.format = f.format.toLowerCase()
    if file.data
      if not content? and f.format? and @convert[f.format+'2txt']?
        try content = await @convert[f.format+'2txt'] file.data
      try content ?= file.data
      try content = content.toString()

  if not content? and not confirmed
    if file? or url?
      f.error = file.error ? 'Could not extract any content'
  else
    contentsmall = if content.length < 20000 then content else content.substring(0, 6000) + content.substring(content.length - 6000, content.length)
    lowercontentsmall = contentsmall.toLowerCase()
    lowercontentstart = (if lowercontentsmall.length < 6000 then lowercontentsmall else lowercontentsmall.substring(0, 6000)).replace(/[^a-z0-9\/]+/g, "")

    f.name ?= meta.title
    try f.checksum = crypto.createHash('md5').update(content, 'utf8').digest('base64')
    f.same_paper_evidence = {} # check if the file meets our expectations
    try f.same_paper_evidence.words_count = content.split(' ').length # will need to be at least 500 words
    try f.same_paper_evidence.words_more_than_threshold = if f.same_paper_evidence.words_count > 500 then true else false
    try f.same_paper_evidence.doi_match = if meta.doi and lowercontentstart.includes(meta.doi.toLowerCase().replace(/[^a-z0-9\/]+/g, "")) then true else false
    try f.same_paper_evidence.title_match = if meta.title and lowercontentstart.includes(meta.title.toLowerCase().replace(/[^a-z0-9\/]+/g, "")) then true else false
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
              an = (a.last ? a.lastname ? a.family ? a.surname ? a.name).trim().split(',')[0].split(' ')[0].toLowerCase().replace(/[^a-z0-9\/]+/g, "")
              af = (a.first ? a.firstname ? a.given ? a.name).trim().split(',')[0].split(' ')[0].toLowerCase().replace(/[^a-z0-9\/]+/g, "")
              inc = lowercontentstart.indexOf an
              if an.length > 2 and af.length > 0 and inc isnt -1 and lowercontentstart.substring(inc-20, inc + an.length+20).includes af
                authorsfound += 1
                if (meta.author.length < 3 and authorsfound is 1) or (meta.author.length > 2 and authorsfound > 1)
                  f.same_paper_evidence.author_match = true
                  break
    if f.format?
      for ft in ['doc','tex','pdf','htm','xml','txt','rtf','odf','odt','page']
        if f.format.includes ft
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
      for l in await @src.google.sheets (if dev then '1XA29lqVPCJ2FQ6siLywahxBTLFaDCZKaN5qUeoTuApg' else '10DNDmOG19shNnuw6cwtCpK-sBnexRCCtD4WnxJx_DPQ')
        try
          f.version_evidence.strings_checked += 1
          wts = l.whattosearch
          if wts.includes('<<') and wts.includes '>>'
            wtm = wts.split('<<')[1].split('>>')[0]
            wts = wts.replace('<<'+wtm+'>>', meta[wtm.toLowerCase()]) if meta[wtm.toLowerCase()]?
          matched = false
          if l.howtosearch is 'string'
            matched = if (l.wheretosearch is 'file' and contentsmall.includes wts) or (l.wheretosearch isnt 'file' and ((meta.title? and meta.title.includes wts) or (f.name? and f.name.includes wts))) then true else false
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
      ls = await @svc.lantern.licence undefined, lowercontentsmall # check lantern for licence info in the file content
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
        f.archivable_reason = 'Since the file is not a PDF, we assume it is an accepted version'
      if not f.archivable and f.licence? and f.licence.toLowerCase().startsWith 'cc'
        f.archivable = true
        f.archivable_reason = 'It appears this file contains a ' + f.lantern.licence + ' licence statement. Under this licence the article can be archived'
      if not f.archivable
        if f.version
          if meta? and JSON.stringify(meta) isnt '{}'
            permissions ?= await @svc.oaworks.permissions meta
          if f.version is permissions?.best_permission?.version
            f.archivable = true
            f.archivable_reason = 'We believe this is a ' + f.version.split('V')[0] + ' version and our permission system says that version can be shared'
          else
            f.archivable_reason ?= 'We believe this file is a ' + f.version.split('V')[0] + ' version and our permission system does not list that as an archivable version'
        else
          f.archivable_reason = 'We cannot confirm if it is an archivable version or not'
    else
      f.archivable_reason ?= if not f.same_paper_evidence.words_more_than_threshold then 'The file is less than 500 words, and so does not appear to be a full article' else if not f.same_paper_evidence.document_format then 'File is an unexpected format ' + f.format else if not meta.doi and not meta.title then 'We have insufficient metadata to validate file is for the correct paper ' else 'File does not contain expected metadata such as DOI or title'

  if f.archivable and not f.licence?
    if permissions?.best_permission?.licence
      f.licence = permissions.best_permission.licence
    else if (permissions?.best_permission?.deposit_statement ? '').toLowerCase().startsWith 'cc'
      f.licence = permissions.best_permission.deposit_statement

  f.metadata = meta
  return f

P.svc.oaworks.archivable._bg = true
