const http	= require('http');
const fs	= require('fs')

let app = http.createServer((req, res) => {
	res.writeHead(200, { 'Content-Type': 'text/html' });
	const data = fs.readFileSync(__dirname + '/index.html', { encoding: 'utf8', flag: 'r' });
	res.end(data);
});

app.listen(30290, '0.0.0.0');
console.log('Node.js app is listening on: 0.0.0.0:30290');