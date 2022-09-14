
P.convert ?= {}

# apt-get install pdftk poppler-utils antiword unoconv #ghostscript tesseract-ocr

P.convert.docxtest = () -> # this works but needs some cleaning up
  cn = await @_child 'unzip',  ['-p', '/home/cloo/static/ExtendedInterval.docx', 'word/document.xml']
  content = ''
  first = true
  for s in cn.split '<w:t'
    if not first
      content += ' ' if not content.endsWith ' '
      content += s.split('>')[1].split('</w:t')[0].replace(/\<.*?\>/g, '')
    first = false
  return content
    
P.convert._content2file = (content) ->
  if not content? and (@params.url or @params.content)
    pc = @params.url ? @params.content
    if pc.startsWith('http://') or (not pc.startsWith('/') and not pc.includes '../')
      content = pc
  if typeof content is 'string' and content.startsWith 'http'
    content = await @fetch content, buffer: true
  if not content and @request.files
    file = @request.files[0]
    file = file[0] if Array.isArray file
    content = file.data
  if typeof content isnt 'string' or not content.startsWith '/'
    fuid = '/tmp/' + await @uid()
    await fs.appendFile fuid, content
  return fuid ? content
  
P.convert.doc2txt = (content) ->
  cn = await @convert._content2file content
  txt = await @_child 'antiword', cn
  await fs.unlink(cn) if typeof cn is 'string' and cn.startsWith '/tmp/'
  return txt

P.convert.docx2txt = (content) ->
  cn = await @convert._content2file content
  await @_child 'unoconv', ['-f', 'doc', cn] # unoconv also has a convenience command set up called doc2pdf
  await fs.unlink(cn) if cn.startsWith '/tmp/'
  cn = cn.replace('.docx', '') + '.doc'
  txt = await @convert.doc2txt cn
  try await fs.unlink(cn) if typeof cn is 'string' and cn.startsWith '/tmp/'
  return txt

P.convert.pdf2txt = (content) ->
  cn = await @convert._content2file content
  txt = await @_child 'pdftotext', [cn, '-']
  await fs.unlink(cn) if typeof cn is 'string' and cn.startsWith '/tmp/'
  return txt

