<!--
WRITING SAMPLE, DRAFT FOR BRYAN'S REVIEW. Not submitted anywhere.
Written for: Amezmo (PHP hosting and deployment tutorials). Also works as the sample for HostingRanked and SigNoz.
Every command and output below was run on a local test site (WordPress 7.1.5, PHP 8.3.14, WP-CLI 2.12.0, SQLite drop-in, PHP built-in server)
on Nov 18, 2026. The crontab lines could not be run under a real cron daemon on the test box (no cron package available there).
Their commands were run with an empty, cron-style environment (`env -i PATH=/usr/bin:/bin`) instead.
Written in Bryan's first-person voice. The only personal claims are: building websites since 2015, mostly WordPress, and testing what he publishes.
No client stories or incidents. Bryan: read it end to end and change anything that doesn't match how you do it.
-->

# WP-Cron Isn't Cron: Moving WordPress Scheduled Tasks to a Real Scheduler (and Proving It Works)

*By Bryan Byfield*

I've been building websites since 2015, mostly on WordPress, and one thing I check early on any site is how its scheduled tasks run. WordPress has a scheduler built in, and most site owners never think about it until something doesn't happen. A scheduled post stays "Missed schedule." A backup plugin reports its last run was three days ago. WooCommerce follow-up emails go out in a burst at 9 a.m. instead of trickling out overnight.

The reason is in the name: WP-Cron isn't cron. It doesn't run on a clock. It runs when someone visits the site. I don't publish steps I haven't run myself, so this tutorial first shows that behavior on a test install I built for it, then moves scheduled tasks to a real system scheduler. It covers WP-CLI, file locking, logging, multisite, and a small check script that tells you when events are falling behind.

## Prerequisites

- SSH access to the server, as the user that owns the WordPress files
- [WP-CLI](https://wp-cli.org/) installed (the examples assume `/usr/local/bin/wp`)
- Permission to edit a crontab, or a hosting dashboard with a cron or scheduled-task feature
- About 20 minutes

## How WP-Cron actually works

When WordPress finishes loading a request, it checks its list of scheduled events, which is stored in the `cron` option in the database. If anything is due, it fires a non-blocking HTTP request back to the site's own `wp-cron.php` (a "loopback" request), and that request runs the due events.

That design has three practical consequences:

1. **No visitors, no cron.** A brochure site that gets a handful of visits overnight runs its "hourly" tasks whenever those visits happen.
2. **Full-page caching can hide your traffic from WordPress.** If a server-level or CDN cache answers a request without starting PHP, WordPress never loads, so it never checks the schedule.
3. **Loopback requests can fail quietly.** Firewalls, basic auth on staging sites, or DNS that doesn't resolve the site's own hostname from inside the server can all block the request to `wp-cron.php`.

### See it for yourself

To make the behavior visible, I used a small must-use plugin that registers a once-a-minute event and writes a line to a log file each time it runs. Save it as `wp-content/mu-plugins/cron-demo.php` on a **test** site:

```php
<?php
/**
 * Plugin Name: Cron Demo
 * Description: Schedules a once-a-minute event that appends a line to a log file.
 */
add_filter( 'cron_schedules', function ( $schedules ) {
	$schedules['every_minute'] = array(
		'interval' => 60,
		'display'  => 'Every minute',
	);
	return $schedules;
} );

add_action( 'init', function () {
	if ( ! wp_next_scheduled( 'cron_demo_tick' ) ) {
		wp_schedule_event( time(), 'every_minute', 'cron_demo_tick' );
	}
} );

add_action( 'cron_demo_tick', function () {
	file_put_contents(
		WP_CONTENT_DIR . '/cron-demo.log',
		gmdate( 'c' ) . " tick\n",
		FILE_APPEND
	);
} );
```

With the plugin in place and nobody visiting the site, I waited 65 seconds. The event was due, but nothing had run:

```console
$ ls wp-content/cron-demo.log
ls: cannot access 'wp-content/cron-demo.log': No such file or directory
$ wp cron event list --fields=hook,next_run_relative | grep demo
cron_demo_tick	now
```

A page view triggered it. The event ran on the back of a visitor's request, not on a schedule:

```console
$ curl -s -o /dev/null http://127.0.0.1:8099/
$ cat wp-content/cron-demo.log
2026-11-18T19:06:41+00:00 tick
```

## Step 1: Take inventory before you change anything

List what's scheduled and how often it repeats:

```bash
wp cron event list --fields=hook,next_run_relative,recurrence
wp cron schedule list
```

On a busy site this list tells you how often the real scheduler needs to run. If the shortest recurrence you see is hourly, running the queue every five minutes is plenty. If something runs every minute (WooCommerce's Action Scheduler, for example, registers its own `every_minute` interval and queue-runner event), match that.

## Step 2: Stop page views from spawning WP-Cron

Add the `DISABLE_WP_CRON` constant to `wp-config.php`. WP-CLI can do it without opening an editor:

```console
$ wp config set DISABLE_WP_CRON true --raw
Success: Added the constant 'DISABLE_WP_CRON' to the 'wp-config.php' file with the raw value 'true'.
```

`wp cron test` now reports that spawning is off. That's what you want here, even though it exits as an error:

```console
$ wp cron test
Error: The DISABLE_WP_CRON constant is set to true. WP-Cron spawning is disabled.
```

To confirm it, I let the demo event come due again and loaded a page. The log didn't change. **From this point nothing runs until you set up a real scheduler**, so do Step 3 right away.

`DISABLE_WP_CRON` doesn't disable the events. It only stops WordPress from spawning `wp-cron.php` on page loads. The events stay in the queue, and anything that runs them still works.

## Step 3: Run due events from the system scheduler

WP-CLI can run everything that's due in one command:

```console
$ wp cron event run --due-now
Executed the cron event 'cron_demo_tick' in 0.011s.
Success: Executed a total of 1 cron event.
```

Now put it in a crontab. Use the crontab of the user that owns the site files, not root's, so files created by scheduled tasks (backups, generated images, caches) get the right owner. On a typical Debian or Ubuntu server where PHP runs as `www-data`, that's `sudo crontab -u www-data -e`:

```cron
*/5 * * * * flock -n /tmp/wp-cron-example.lock timeout 10m /usr/bin/php /usr/local/bin/wp cron event run --due-now --path=/var/www/example.com/public --quiet >> /var/log/wp-cron/example.log 2>&1
```

Each part of that line is there for a reason:

- **`*/5 * * * *`** runs every five minutes. Use `* * * * *` if Step 1 turned up per-minute events.
- **`flock -n /tmp/wp-cron-example.lock`** stops runs from piling up. If a slow task is still running when the next run starts, the new one exits instead of starting a second copy. On the test site, a second run started while the lock was held exited right away with status `1`.
- **`timeout 10m`** kills a run that hangs, so a stuck HTTP call inside a plugin can't hold the lock forever.
- **`/usr/bin/php /usr/local/bin/wp`** uses absolute paths. Cron starts jobs with a very small `PATH`. WP-CLI's first line is `#!/usr/bin/env php`, so if PHP lives anywhere cron's `PATH` doesn't cover, the job fails before WordPress loads. I reproduced this by running the command with an empty, cron-style environment:

  ```console
  $ env -i PATH=/usr/bin:/bin sh -c '/usr/local/bin/wp cron event run --due-now --path=/var/www/example.com/public'
  env: 'php': No such file or directory
  ```

  Calling PHP by its full path fixed it. Run `command -v php` and `command -v wp` on your server and use what they print.
- **`--path=`** lets the job run from any working directory.
- **`--quiet`** drops the "Success" lines, so the log only grows when something goes wrong. Errors still go to stderr, and `2>&1` sends them to the log.

Create the log directory first and give it to the same user (`sudo mkdir -p /var/log/wp-cron && sudo chown www-data: /var/log/wp-cron`).

### On managed hosting

You don't need a raw crontab for this. Most PHP hosts have a scheduled-task screen that does the same job. On Amezmo, for example, a cron entry is a name, a schedule, and a bash script, and [Amezmo's docs](https://www.amezmo.com/docs/cron/creating-entries) say it runs as the `deployer` user. The WP-CLI command above goes in the script body. The schedule and the absolute paths are the parts that matter.

## Step 4: Multisite needs one run per site

On multisite, every site has its own cron queue, and `wp cron event run` without `--url` only handles the main site. On a two-site test network, I queued a due event on both sites and ran the command without `--url`. The main site's event ran. The second site's event was still waiting:

```console
$ wp cron event list --url=http://127.0.0.1:8098/second/ --fields=hook,next_run_relative | grep late_demo_ms
late_demo_ms	now
```

Loop over the sites instead:

```bash
wp site list --field=url | xargs -I {} /usr/bin/php /usr/local/bin/wp cron event run --due-now --url={} --quiet
```

Wrap that in a small script and point the crontab line at the script. That keeps the `flock` and `timeout` around the whole loop.

## Step 5: When you can't use WP-CLI

Some hosts let you schedule a URL but not a shell command. In that case, request `wp-cron.php` directly:

```cron
*/5 * * * * curl -fsS --max-time 60 "https://example.com/wp-cron.php?doing_wp_cron" > /dev/null
```

This still works with `DISABLE_WP_CRON` set to `true`. On the test site, an overdue event left the queue after a single `curl` to `wp-cron.php`. The trade-off is that the run goes through the web server, so it's subject to PHP's web time limits, security plugins, and any rules that block `wp-cron.php`. Use WP-CLI when you can.

## Step 6: Know when it stops working

A scheduler that fails quietly is how you ended up reading this article. Here's a small check that exits with an error if any event is more than 15 minutes overdue:

```bash
#!/bin/bash
# wp-cron-check.sh: exit 1 if any WP-Cron event is more than MAX_LATE seconds overdue.
WP="/usr/bin/php /usr/local/bin/wp"
SITE=/var/www/example.com/public
MAX_LATE=${1:-900}

now=$(date +%s)
late=$($WP cron event list --path="$SITE" --fields=hook,time --format=csv \
  | tail -n +2 \
  | awk -F, -v now="$now" -v max="$MAX_LATE" \
      '($2 + max) < now { print $1 " is " (now - $2) "s overdue" }')

if [ -n "$late" ]; then
  echo "$late"
  exit 1
fi
echo "OK: no events more than ${MAX_LATE}s overdue"
```

To test it, I queued an event an hour in the past with `wp eval 'wp_schedule_single_event( time() - 3600, "late_demo" );'`:

```console
$ ./wp-cron-check.sh 900
late_demo is 3600s overdue
$ echo $?
1
$ wp cron event run --due-now
Executed the cron event 'late_demo' in 0.004s.
Success: Executed a total of 1 cron event.
$ ./wp-cron-check.sh 900
OK: no events more than 900s overdue
```

Run it hourly from cron and send its output wherever you already get alerts: email through cron's `MAILTO`, a push to an uptime monitor's heartbeat URL only when it exits `0`, or your log pipeline.

## Rolling back

If anything goes wrong, remove the crontab line and run `wp config delete DISABLE_WP_CRON`. WordPress goes back to spawning WP-Cron on page views on the next request, and nothing in the event queue is lost.

## Wrapping up

WP-Cron is a reasonable default for a site that gets steady traffic and runs on hosting you can't configure. Once a site depends on scheduled work, like publishing, backups, store emails, or imports, that work should run on a clock. The change is one constant and one crontab line. A lock, a timeout, absolute paths, and an overdue check make it something you don't have to think about again.

---

*I'm Bryan Byfield, a web developer in San Bernardino, California. I've been building and maintaining websites since 2015, mostly on WordPress, and I test every command I publish. You can reach me at bryanbyfield0@gmail.com.*
