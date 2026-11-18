# Stopping WordPress login and XML-RPC brute force with Fail2ban

A tested, step-by-step guide by Bryan Byfield: [fail2ban-wordpress.md](fail2ban-wordpress.md)

Config files used in the guide (tested on Debian with Nginx, Fail2ban and nftables):

- `config/wordpress-login.conf`: filter for failed `wp-login.php` logins (POST returning 200)
- `config/wordpress-xmlrpc.conf`: filter for `xmlrpc.php` POSTs
- `config/jail.d-wordpress.conf`: the two jails (copy to `/etc/fail2ban/jail.d/wordpress.conf`)

More: https://github.com/bryanbyfield0-creator
