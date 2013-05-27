var http = require('http')
var url  = require('url')

var port = process.env.VMC_APP_PORT || 8080;

var server = http.createServer(function(req, res) {
  var path = url.parse(req.url).pathname;
  console.log("path: " + path + " method: " + req.method);

  if(req.method === 'GET') {
    if(path === '/') {
      res.writeHead(200, { 'content-type': 'text/plain' });
      res.end('node.js app');
    }
    else if(path === '/hello') {
      res.writeHead(200, { 'content-type': 'text/plain' });
      res.end('hello, world');
    }
    else if(path === '/crash') {
      res.writeHead(200, { 'content-type': 'text/plain' });
      setTimeout(function() {
        process.exit();
      }, 1000);
      res.end('seppuku');
    }
    else if(path.indexOf('/data/') === 0){
      res.writeHead(200, { 'content-type': 'text/plain' });
      size = path.substr('/data/'.length);
      for(var i = 0; i < size; i++) {
        res.write('x');
      }
      res.end('');
    }
    else {
      res.writeHead(404);
      res.end('');
    }
  }
  else if(req.method === 'PUT' && path === '/data') {
    res.writeHead(200, { 'content-type': 'text/plain' });
    req.on('data', function(chunk){
      res.end("received " + chunk.length + " bytes");
    });
  }
  else {
    res.writeHead(404);
    res.end('');
  }
});

server.listen(port);

