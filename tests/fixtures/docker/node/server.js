import http from 'http';

const server = http.createServer((req, res) => {
  if (req.url === '/healthz') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'healthy' }));
  } else {
    res.writeHead(404);
    res.end();
  }
});

server.listen(3000, '0.0.0.0', () => {
  console.log('Node fixture server listening on 3000');
});
