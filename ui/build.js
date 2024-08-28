const shell = require('shelljs');

shell.mkdir('-p', 'dist');

shell.cp(['dashboard/index.html', 'dashboard/reset.css'], 'dist/');
