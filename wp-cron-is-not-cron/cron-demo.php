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
