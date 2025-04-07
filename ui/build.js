const shell = require('shelljs');

shell.mkdir('-p', 'dist');

shell.cp(['dashboard/index.html', 'dashboard/reset.css'], 'dist/');

// Not needed, but added temporarily to make dashboards work in a standalone web browser:
shell.cp(['dashboard/web-ui-config.json'], 'dist/');
