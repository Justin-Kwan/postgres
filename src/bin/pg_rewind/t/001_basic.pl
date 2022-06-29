
# Copyright (c) 2021-2022, PostgreSQL Global Development Group

use strict;
use warnings;
use PostgreSQL::Test::Utils;
use Test::More;

use FindBin;
use lib $FindBin::RealBin;

use RewindTest;

sub run_test
{
	my $test_mode = shift;

	RewindTest::setup_cluster($test_mode);
	RewindTest::start_primary();

	# Create a test table and insert a row in primary.
	primary_psql("CREATE TABLE tbl1 (d text)");
	primary_psql("INSERT INTO tbl1 VALUES ('in primary')");

	# This test table will be used to test truncation, i.e. the table
	# is extended in the old primary after promotion
	primary_psql("CREATE TABLE trunc_tbl (d text)");
	primary_psql("INSERT INTO trunc_tbl VALUES ('in primary')");

	# This test table will be used to test the "copy-tail" case, i.e. the
	# table is truncated in the old primary after promotion
	primary_psql("CREATE TABLE tail_tbl (id integer, d text)");
	primary_psql("INSERT INTO tail_tbl VALUES (0, 'in primary')");

	# This test table is dropped in the old primary after promotion.
	primary_psql("CREATE TABLE drop_tbl (d text)");
	primary_psql("INSERT INTO drop_tbl VALUES ('in primary')");

	primary_psql("CHECKPOINT");

	RewindTest::create_standby($test_mode);

	# Insert additional data on primary that will be replicated to standby
	primary_psql("INSERT INTO tbl1 values ('in primary, before promotion')");
	primary_psql(
		"INSERT INTO trunc_tbl values ('in primary, before promotion')");
	primary_psql(
		"INSERT INTO tail_tbl SELECT g, 'in primary, before promotion: ' || g FROM generate_series(1, 10000) g"
	);

	primary_psql('CHECKPOINT');

	RewindTest::promote_standby();

	# Insert a row in the old primary. This causes the primary and standby
	# to have "diverged", it's no longer possible to just apply the
	# standy's logs over primary directory - you need to rewind.
	primary_psql("INSERT INTO tbl1 VALUES ('in primary, after promotion')");

	# Also insert a new row in the standby, which won't be present in the
	# old primary.
	standby_psql("INSERT INTO tbl1 VALUES ('in standby, after promotion')");

	# Insert enough rows to trunc_tbl to extend the file. pg_rewind should
	# truncate it back to the old size.
	primary_psql(
		"INSERT INTO trunc_tbl SELECT 'in primary, after promotion: ' || g FROM generate_series(1, 10000) g"
	);

	# Truncate tail_tbl. pg_rewind should copy back the truncated part
	# (We cannot use an actual TRUNCATE command here, as that creates a
	# whole new relfilenode)
	primary_psql("DELETE FROM tail_tbl WHERE id > 10");
	primary_psql("VACUUM tail_tbl");

	# Drop drop_tbl. pg_rewind should copy it back.
	primary_psql(
		"insert into drop_tbl values ('in primary, after promotion')");
	primary_psql("DROP TABLE drop_tbl");

	# Record last modification time of WAL segment file common between both
	# source and target, stored on current primary server. pg_rewind should
	# refrain from overwriting this file with the source's newly forked copy.
	$node_primary->psql(
		'postgres',
		"SELECT extract(epoch from modification) FROM pg_stat_file('pg_wal/000000010000000000000002');",
		stdout => \my $common_wal_modified_at);

	# Record last modification time of WAL segment file that is partially
	# written to just before the new timeline, but still common between both
	# source and target. pg_rewind should overwrite this file with the source's
	# copy to be safe.
	$node_primary->psql(
		'postgres',
		"SELECT extract(epoch from modification) FROM pg_stat_file('pg_wal/000000010000000000000003');",
		stdout => \my $last_common_tli1_wal_modified_at);

	# Record last modification time of first diverged WAL segment file on the
	# old primary's timeline. pg_rewind should overwrite this file with the
	# source's newly forked copy.
	$node_primary->psql(
		'postgres',
		"SELECT extract(epoch from modification) FROM pg_stat_file('pg_wal/000000020000000000000003');",
		stdout => \my $last_common_tli2_wal_modified_at);

	# Before running pg_rewind, do a couple of extra tests with several
	# option combinations.  As the code paths taken by those tests
	# do not change for the "local" and "remote" modes, just run them
	# in "local" mode for simplicity's sake.
	if ($test_mode eq 'local')
	{
		my $primary_pgdata = $node_primary->data_dir;
		my $standby_pgdata = $node_standby->data_dir;

		# First check that pg_rewind fails if the target cluster is
		# not stopped as it fails to start up for the forced recovery
		# step.
		command_fails(
			[
				'pg_rewind',       '--debug',
				'--source-pgdata', $standby_pgdata,
				'--target-pgdata', $primary_pgdata,
				'--no-sync'
			],
			'pg_rewind with running target');

		# Again with --no-ensure-shutdown, which should equally fail.
		# This time pg_rewind complains without attempting to perform
		# recovery once.
		command_fails(
			[
				'pg_rewind',       '--debug',
				'--source-pgdata', $standby_pgdata,
				'--target-pgdata', $primary_pgdata,
				'--no-sync',       '--no-ensure-shutdown'
			],
			'pg_rewind --no-ensure-shutdown with running target');

		# Stop the target, and attempt to run with a local source
		# still running.  This fails as pg_rewind requires to have
		# a source cleanly stopped.
		$node_primary->stop;
		command_fails(
			[
				'pg_rewind',       '--debug',
				'--source-pgdata', $standby_pgdata,
				'--target-pgdata', $primary_pgdata,
				'--no-sync',       '--no-ensure-shutdown'
			],
			'pg_rewind with unexpected running source');

		# Stop the target cluster cleanly, and run again pg_rewind
		# with --dry-run mode.  If anything gets generated in the data
		# folder, the follow-up run of pg_rewind will most likely fail,
		# so keep this test as the last one of this subset.
		$node_standby->stop;
		command_ok(
			[
				'pg_rewind',       '--debug',
				'--source-pgdata', $standby_pgdata,
				'--target-pgdata', $primary_pgdata,
				'--no-sync',       '--dry-run'
			],
			'pg_rewind --dry-run');

		# Both clusters need to be alive moving forward.
		$node_standby->start;
		$node_primary->start;
	}

	RewindTest::run_pg_rewind($test_mode);

	check_query(
		'SELECT * FROM tbl1',
		qq(in primary
in primary, before promotion
in standby, after promotion
),
		'table content');

	check_query(
		'SELECT * FROM trunc_tbl',
		qq(in primary
in primary, before promotion
),
		'truncation');

	check_query(
		'SELECT count(*) FROM tail_tbl',
		qq(10001
),
		'tail-copy');

	check_query(
		'SELECT * FROM drop_tbl',
		qq(in primary
),
		'drop');

	if ($test_mode eq 'local' || $test_mode eq 'remote')
	{
		# Last modification time of WAL segment files common between both
		# source and target is unchanged on the target. This indicates that
		# pg_rewind skipped copying the source's files and overwriting the
		# target's files.
		$node_primary->psql(
			'postgres',
			"SELECT extract(epoch from modification) FROM pg_stat_file('pg_wal/000000010000000000000002');",
			stdout => \my $common_wal_last_modified_at);

		cmp_ok($common_wal_last_modified_at,
			'==', $common_wal_modified_at,
			'common WAL segment file on target, before divergence, not overwritten');

		# Last modification time of WAL segment files just before and after
		# the new timeline should now be further ahead. (Both of these WAL
		# files are internally represented by segment 3.) This indicates that
		# pg_rewind copied the source's files and overwrote the target's files.
		$node_primary->psql(
			'postgres',
			"SELECT extract(epoch from modification) FROM pg_stat_file('pg_wal/000000010000000000000003');",
			stdout => \my $last_common_tli1_wal_last_modified_at);

		cmp_ok($last_common_tli1_wal_last_modified_at,
			'>=', $last_common_tli1_wal_modified_at,
			'last common WAL segment file on target, before divergence, overwritten');

		$node_primary->psql(
			'postgres',
			"SELECT extract(epoch from modification) FROM pg_stat_file('pg_wal/000000020000000000000003');",
			stdout => \my $last_common_tli2_wal_last_modified_at);

		cmp_ok($last_common_tli2_wal_last_modified_at,
			'>', $last_common_tli2_wal_modified_at,
			'last common WAL segment file on target, before divergence, overwritten');
	}

	# Permissions on PGDATA should be default
  SKIP:
	{
		skip "unix-style permissions not supported on Windows", 1
		  if ($windows_os);

		ok(check_mode_recursive($node_primary->data_dir(), 0700, 0600),
			'check PGDATA permissions');
	}

	RewindTest::clean_rewind_test();
	return;
}

# Run the test in both modes
run_test('local');
run_test('remote');
run_test('archive');

done_testing();
