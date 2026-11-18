<!--
DRAFT FOR BRYAN'S REVIEW. Not published.
Tested on the box on Nov 18, 2026: Debian 13, Nginx 1.26.3 (reverse-proxying to WordPress 7.1.5 on PHP 8.3), Fail2ban 1.1.0 (Debian 1.1.0-8), nftables 1.1.3.
Test "attackers" were extra loopback addresses (127.0.0.2-127.0.0.7) sent with curl --interface. Bans were real nftables rules on ports 80/443.
The box has no systemd, so Fail2ban was started with `fail2ban-client start`. The systemctl command is mentioned as the standard alternative, not tested here.
The Debian sshd jail was turned off on the test box only, because there's no journal there.
-->

# Stopping WordPress Login and XML-RPC Brute Force with Fail2ban

*By Bryan Byfield*

I've been building websites since 2015, mostly on WordPress. Any WordPress site on the public internet is a target for bots that guess passwords on `wp-login.php` and `xmlrpc.php`, because both endpoints are in the same place on every install. A strong password keeps them out, but it doesn't stop them trying. Every guess is a full PHP request and at least one database query, and on a small VPS a steady flood of them adds up.

Security plugins can rate-limit logins, but by the time a plugin runs, the server has already started PHP and loaded WordPress to handle the request. Fail2ban works a level lower. It reads the web server's access log, counts failed attempts per IP address, and adds a firewall rule that blocks the IP before its requests reach Nginx or PHP.

In this tutorial I set up two Fail2ban jails, one for login form attacks and one for XML-RPC, test the filters against real log lines, and show the bans working. I don't publish steps I haven't run myself. Everything below was tested on Debian 13 with Nginx 1.26.3, Fail2ban 1.1.0, nftables 1.1.3 and WordPress 7.1.5.

## Prerequisites

- A Linux server where you have root (or sudo) access. Shared hosting won't let you run Fail2ban.
- Nginx or Apache writing a standard access log
- Fail2ban and a firewall backend. On Debian or Ubuntu, `sudo apt install fail2ban nftables` installs both.
- A second way into the server in case you lock yourself out, such as your host's web console

## How a failed login looks in the log

To write a filter, you need to know what a failed login looks like compared with a successful one. WordPress helps here. A failed login re-displays the login form with a `200` status, and a successful login redirects to the dashboard with a `302`.

I confirmed that on my test site by sending one wrong password and one correct password, then reading Nginx's access log:

```console
127.0.0.2 - - [18/Nov/2026:13:23:43 -0700] "POST /wp-login.php HTTP/1.1" 200 6116 "-" "curl/8.14.1"
127.0.0.1 - - [18/Nov/2026:13:23:43 -0700] "POST /wp-login.php HTTP/1.1" 302 5 "-" "curl/8.14.1"
```

So the rule is simple: **a `POST` to `wp-login.php` that returns `200` is a failed attempt.** Page views of the login form are `GET` requests, so they don't count.

XML-RPC is harder. A failed login there still returns `200`, with the error buried in the XML body:

```xml
<member><name>faultCode</name><value><int>403</int></value></member>
<member><name>faultString</name><value><string>Incorrect username or password.</string></value></member>
```

The access log can't tell a failed XML-RPC call from a good one. XML-RPC also accepts `system.multicall`, which bundles many password guesses into a single request. That's why the XML-RPC jail below counts *every* `POST` and uses a higher threshold.

## Step 1: Write the filters

Fail2ban filters live in `/etc/fail2ban/filter.d/`. Create `/etc/fail2ban/filter.d/wordpress-login.conf`:

```ini
# Failed WordPress logins: a POST to wp-login.php that returns 200.
# (A successful login redirects with a 302, so it never matches.)
[Definition]
failregex = ^<HOST> [^"]*"POST /wp-login\.php[^"]*" 200\b
ignoreregex =
```

And `/etc/fail2ban/filter.d/wordpress-xmlrpc.conf`:

```ini
# Any POST to xmlrpc.php. Failed logins there still return 200, so count every request.
[Definition]
failregex = ^<HOST> [^"]*"POST /xmlrpc\.php[^"]*"
ignoreregex =
```

`<HOST>` is Fail2ban's placeholder for the IP address it should track. `[^"]*` skips the rest of the line up to the request, and `[^"]*"` after the path allows query strings like `?action=lostpassword` before matching the status code.

### The mistake I made first

My first version of the login filter spelled out the whole log line, timestamp included:

```ini
failregex = ^<HOST> \S+ \S+ \[[^\]]+\] "POST /wp-login\.php[^"]*" 200
```

It matched nothing. Fail2ban finds the timestamp in each line and **removes it before applying your regex**, so a pattern that expects `[18/Nov/2026:...]` never matches. Don't write the date into the pattern. Skip past it the way the filters above do.

## Step 2: Test the filters before you trust them

`fail2ban-regex` runs a filter against a log file and reports what it matched, without banning anything. Run it every time you change a filter:

```console
$ sudo fail2ban-regex --print-all-matched /var/log/nginx/access.log /etc/fail2ban/filter.d/wordpress-login.conf
...
Lines: 4 lines, 0 ignored, 1 matched, 3 missed
|  127.0.0.2 - - [18/Nov/2026:13:23:43 -0700] "POST /wp-login.php HTTP/1.1" 200 6116 "-" "curl/8.14.1"
```

My test log had four lines: a `GET` of the login page, the failed login, the successful login and an XML-RPC call. The login filter matched only the failed login, which is what I wanted. The XML-RPC filter matched only the XML-RPC line.

If you see `0 matched` on a log you know contains failed logins, check your log format. These filters expect Nginx's default `combined` format, which starts with the client IP. Apache's `combined` format puts the same fields in the same order. I tested with Nginx.

## Step 3: Create the jails

A jail ties a filter to a log file and sets the thresholds. Create `/etc/fail2ban/jail.d/wordpress.conf`:

```ini
[wordpress-login]
enabled  = true
port     = http,https
filter   = wordpress-login
logpath  = /var/log/nginx/access.log
maxretry = 5
findtime = 10m
bantime  = 1h

[wordpress-xmlrpc]
enabled  = true
port     = http,https
filter   = wordpress-xmlrpc
logpath  = /var/log/nginx/access.log
maxretry = 10
findtime = 5m
bantime  = 1h
```

Five failed logins within 10 minutes gets an IP blocked from ports 80 and 443 for an hour. For XML-RPC, ten requests in five minutes does the same. If nothing on your site uses XML-RPC (some plugins and apps still do, and Jetpack has historically relied on it), you can lower that threshold or block the endpoint entirely.

Change `logpath` if your site writes to its own log file, such as `/var/log/nginx/example.com.access.log`.

On Debian and Ubuntu, the packaged `/etc/fail2ban/jail.d/defaults-debian.conf` already sets `banaction = nftables`, so bans become nftables rules. If your distribution still uses iptables, the default action works too.

### Don't ban yourself

Put the addresses you always connect from in `/etc/fail2ban/jail.local`:

```ini
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1 203.0.113.10
```

Replace `203.0.113.10` with your own static IP. To test it, I set `ignoreip = 127.0.0.1/8 ::1` and sent seven failed logins from `127.0.0.7`. Fail2ban logged `Ignore 127.0.0.7 by ip` instead of banning it.

Check the configuration, then load it. If Fail2ban isn't running yet, start it with `sudo systemctl start fail2ban` (or `sudo fail2ban-client start` on a system without systemd, which is how I ran my test server):

```console
$ sudo fail2ban-client -t
OK: configuration test is successful
$ sudo fail2ban-client reload
OK
$ sudo fail2ban-client status
Status
|- Number of jail:	2
`- Jail list:	wordpress-login, wordpress-xmlrpc
```

On a server that already runs the `sshd` jail, that list will include it too.

## Step 4: Watch a ban happen

To prove the jails work, I sent six successful logins from one address, then six failed logins from another:

```console
== 6 successful logins from 127.0.0.5
302 302 302 302 302 302
== 6 failed logins from 127.0.0.4
200 200 200 200 200 200
```

Fail2ban banned the failing address and left the successful one alone:

```console
$ sudo fail2ban-client status wordpress-login
...
   `- Banned IP list:	127.0.0.4
```

The ban is a real firewall rule. Fail2ban creates its own nftables table:

```console
$ sudo nft list ruleset
table inet f2b-table {
	set addr-set-wordpress-login {
		type ipv4_addr
		elements = { 127.0.0.4 }
	}

	chain f2b-chain {
		type filter hook input priority filter - 1; policy accept;
		tcp dport { 80, 443 } ip saddr @addr-set-wordpress-login reject with icmp port-unreachable
	}
}
```

From the banned address, the next request couldn't even connect (`curl` exit code 7). The address that logged in successfully still got a normal `200`. The banned requests never reached Nginx, so they never started PHP or WordPress.

The XML-RPC jail behaved the same way. Eleven `system.multicall` requests from a third address, each carrying a wrong password, got it banned from the web ports.

## Step 5: Unban, and read the history

If you or a client gets caught, lift the ban for one jail:

```console
$ sudo fail2ban-client set wordpress-xmlrpc unbanip 127.0.0.6
1
```

Fail2ban logs every ban and unban in `/var/log/fail2ban.log`, which makes it easy to see what happened:

```console
$ sudo grep -E 'Ban|Unban' /var/log/fail2ban.log | tail -n 3
... NOTICE  [wordpress-login] Ban 127.0.0.4
... NOTICE  [wordpress-xmlrpc] Ban 127.0.0.6
... NOTICE  [wordpress-xmlrpc] Unban 127.0.0.6
```

Bans also survive a Fail2ban reload. After I ran `sudo fail2ban-client reload`, the banned address was still in the list.

## One important warning: proxies and CDNs

All of this depends on the first field of the access log being the visitor's real IP address. If your site sits behind Cloudflare, a load balancer or another reverse proxy, Nginx logs the *proxy's* address for every request. Fail2ban would then ban the proxy, which takes the whole site offline for everyone coming through it.

If you're behind a proxy, configure Nginx's real IP module (`set_real_ip_from` and `real_ip_header`) so the log shows visitor addresses, and confirm it in the log *before* you enable these jails. Also, a firewall ban on your origin server does nothing to traffic the CDN is still accepting on your behalf.

## Wrapping up

Two short filter files and one jail file are enough to stop most password guessing against a WordPress site at the firewall instead of in PHP. The main lessons from testing it:

- Base the login filter on the status code: `200` means failed, `302` means success.
- Count every XML-RPC `POST`, because the log can't tell a failed one from a good one.
- Leave the timestamp out of your regex, and test every filter with `fail2ban-regex`.
- Add your own IPs to `ignoreip`, and check that the log shows real visitor IPs before you trust any ban.

Keep strong passwords and two-factor authentication too. Fail2ban cuts the noise and the load, but it isn't a substitute for either.

---

*I'm Bryan Byfield, a web developer in San Bernardino, California. I've been building and maintaining websites since 2015, mostly on WordPress, and I test every command I publish. You can reach me at bryanbyfield0@gmail.com, and more of my tutorials are at https://github.com/bryanbyfield0-creator.*
