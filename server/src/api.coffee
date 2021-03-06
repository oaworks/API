
# use forever or pm2 to run on server
# https://www.digitalocean.com/community/tutorials/how-to-set-up-a-node-js-application-for-production-on-ubuntu-16-04

import fetch from 'node-fetch' # used in fetch - does this expose wide enough scope or does it need hoisted?
import http from 'http'
import https from 'https' # allows fetch to control https security for local connections
import Busboy from 'busboy'

http.createServer((req, res) ->
  #try
  if req.headers?['content-type']?.match /^multipart\/form\-data/
    # example: curl -X POST 'https://a2s.lvatn.com/convert?from=xls&to=csv' -F file=@anexcelfile.xlsx
    busboy = new Busboy headers: req.headers
    req.files = []
    req.body ?= {}
    waiting = true
    busboy.on 'file', (fieldname, file, filename, encoding, mimetype) ->
      uf = {
        filename, 
        mimetype, 
        encoding, 
        fieldname, 
        data: null
      }
      buffers = []
      file.on 'data', (data) ->
        buffers.push data
      file.on 'end', () ->
        uf.data = Buffer.concat buffers
        req.files.push uf
    busboy.on 'field', (fieldname, value) -> req.body[fieldname] = value
    busboy.on 'finish', () -> waiting = false
    req.pipe busboy
    
    while waiting
      await new Promise (resolve) => setTimeout resolve, 200
      
  try
    pr = await P.call request: req # how does this req compare to the event.request passed by fetch in P?
    try console.log(pr.status + ' ' + req.url) if S.dev
    try pr.headers['x-' + S.name + '-bg'] = true
    if req.url is '/'
      try
        pb = JSON.parse pr.body
        pb.bg = true
        pr.body = JSON.stringify pb, '', 2
        pr.headers['Content-Length'] = Buffer.byteLength pr.body
    #if typeof pr.body isnt 'string' # could there be buffers here?
    #  try
    #    pr.body = JSON.stringify pr.body, '', 2
    #    pr.headers['Content-Length'] = Buffer.byteLength pr.body
    res.writeHead pr.status, pr.headers # where would these be in a Response object from P?
    res.end pr.body
  catch err
    try console.log err
    headers = {}
    headers['x-' + S.name + '-bg'] = true
    res.writeHead 405, headers # where would these be in a Response object from P?
    res.end '405'
).listen S.port ? 4000, 'localhost'

console.log S.name + ' v' + S.version + ' built ' + S.built + ', listening on ' + (S.port ? 4000)