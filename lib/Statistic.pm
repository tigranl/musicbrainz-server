#____________________________________________________________________________
#
#   MusicBrainz -- the open internet music database
#
#   Copyright (C) 2000 Robert Kaye
#
#   This program is free software; you can redistribute it and/or modify
#   it under the terms of the GNU General Public License as published by
#   the Free Software Foundation; either version 2 of the License, or
#   (at your option) any later version.
#
#   This program is distributed in the hope that it will be useful,
#   but WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#   GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public License
#   along with this program; if not, write to the Free Software
#   Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.
#
#   $Id$
#____________________________________________________________________________

package Statistic;

use strict;
use Sql;
use ModDefs;

sub new
{
	my ($type, $dbh) = @_;

	my $this = { DBH => $dbh };
	return bless $this, $type;
}

# Fetch current stat(s)
# $value = $stat->Fetch($name)
# @values = $stat->Fetch(@names)

sub Fetch
{
	my ($self, @names) = @_;
	return unless @names;

	my $sql = Sql->new($self->GetDBH);

	my %s;
	@s{@names} = ();

	my $qs = join ", ", (("?") x scalar(keys %s));
	my $data = $sql->SelectListOfLists(
		"SELECT name, value FROM currentstat WHERE name IN ($qs)",
		keys(%s),
	);

	for (@$data)
	{
		$s{ $_->[0] } = $_->[1];
	}

	unless (wantarray)
	{
		my $v = $s{$names[0]};
		warn "No stat data for '$names[0]'" unless defined $v;
		return $v;
	}

	@s{@names};
}

# Fetch all currentstat as a hash reference

sub FetchAllAsHashRef
{
	my $self = shift;

	my $sql = Sql->new($self->GetDBH);

	my $data = $sql->SelectListOfLists(
		"SELECT name, value FROM currentstat",
	);

	+{
		map { @$_ } @$data
	};
}

# Write stats into currentstat.
# $stat->Update(name => value, name => value, ...);

sub Update
{
	my $self = shift;
	my $sql = Sql->new($self->GetDBH);

	$sql->Do("LOCK TABLE currentstat IN EXCLUSIVE MODE");

	while (my ($name, $value) = splice(@_, 0, 2))
	{
		print "Stat $name = $value\n" if -t STDOUT;

		$sql->Do(
			"UPDATE currentstat SET value = ?, lastupdated = NOW() WHERE name = ?",
			$value,
			$name,
		)
			or
		$sql->Do(
			"INSERT INTO currentstat (name, value, lastupdated) VALUES (?, ?, NOW())",
			$name,
			$value,
		);
	}
}

# Find "the time" at which the current stats were taken.
# Actually the timestamp of the oldest stat.

sub LastRefreshed
{
	my $self = shift;
	my $sql = Sql->new($self->GetDBH);
	$sql->SelectSingleValue("SELECT MIN(lastupdated) FROM currentstat");
}

# Take a snapshot of all of the currentstat data as today's historicalstat
# Deletes today's historicalstat first if required.

sub TakeSnapshot
{
	my $self = shift;
	my $sql = Sql->new($self->GetDBH);

	my $date = $sql->SelectSingleValue("SELECT current_date");

	$sql->Do(
		"DELETE FROM historicalstat WHERE snapshotdate = ?",
		$date,
	);

	$sql->Do(
		"INSERT INTO historicalstat (name, value, snapshotdate)
			SELECT name, value, ? FROM currentstat",
		$date,
	);
}

################################################################################

my %stats = (
	"count.album" => {
		DESC => "Count of all releases",
		SQL => "SELECT COUNT(*) FROM album",
	},
	"count.artist" => {
		DESC => "Count of all artists",
		SQL => "SELECT COUNT(*) FROM artist",
	},
	"count.label" => {
		DESC => "Count of all labels",
		SQL => "SELECT COUNT(*) FROM label",
	},
	"count.discid" => {
		DESC => "Count of all disc IDs",
		SQL => "SELECT COUNT(*) FROM album_cdtoc",
	},
	"count.moderation" => {
		DESC => "Count of all edits",
		SQL => "SELECT COUNT(*) FROM moderation_all",
	},
	"count.moderator" => {
		DESC => "Count of all editors",
		SQL => "SELECT COUNT(*) FROM moderator",
	},
	"count.puid" => {
		DESC => "Count of all PUIDs joined to tracks",
		SQL => "SELECT COUNT(*) FROM puidjoin",
	},
	"count.puid.ids" => {
		DESC => "Count of unique PUIDs",
		SQL => "SELECT COUNT(DISTINCT puid) FROM puidjoin",
	},
	"count.track" => {
		DESC => "Count of all tracks",
		SQL => "SELECT COUNT(*) FROM track",
	},
	"count.vote" => {
		DESC => "Count of all votes",
		SQL => "SELECT COUNT(*) FROM vote_all",
	},

	"count.album.various" => {
		DESC => "Count of all 'Various Artists' releases",
		SQL => "SELECT COUNT(*) FROM album WHERE artist = " . &ModDefs::VARTIST_ID,
	},
	"count.album.nonvarious" => {
		DESC => "Count of all 'Various Artists' releases",
		PREREQ => [qw[ count.album count.album.various ]],
		CALC => sub {
			my ($self, $sql) = @_;

			$self->Fetch("count.album")
				- $self->Fetch("count.album.various")
		},
	},

	"count.album.has_discid" => {
		DESC => "Count of releases with at least one disc ID",
		SQL => "SELECT COUNT(DISTINCT album) FROM album_cdtoc",
	},
	"count.album.Ndiscids" => {
		DESC => "Distribution of disc IDs per release (varying disc IDs)",
		PREREQ => [qw[ count.album count.album.has_discid ]],
		CALC => sub {
			my ($self, $sql) = @_;

			my $max_dist_tail = 10;

			my $data = $sql->SelectListOfLists(
				"SELECT c, COUNT(*) AS freq
				FROM (
					SELECT album, COUNT(*) AS c
					FROM album_cdtoc
					GROUP BY album
				) AS t
				GROUP BY c
				",
			);

			my %dist = map { $_ => 0 } 1 .. $max_dist_tail;

			for (@$data)
			{
				$dist{ $_->[0] } = $_->[1], next
					if $_->[0] < $max_dist_tail;

				$dist{$max_dist_tail} += $_->[1];
			}

			$dist{0} = $self->Fetch("count.album")
				- $self->Fetch("count.album.has_discid");
			
			+{
				map {
					"count.album.".$_."discids" => $dist{$_}
				} keys %dist
			};
		},
	},

	"count.puid.Ntracks" => {
		DESC => "Distribution of tracks per PUID (collisions)",
		CALC => sub {
			my ($self, $sql) = @_;

			my $max_dist_tail = 10;

			my $data = $sql->SelectListOfLists(
				"SELECT c, COUNT(*) AS freq
				FROM (
					SELECT puid, COUNT(*) AS c
					FROM puidjoin
					GROUP BY puid
				) AS t
				GROUP BY c
				",
			);

			my %dist = map { $_ => 0 } 1 .. $max_dist_tail;

			for (@$data)
			{
				$dist{ $_->[0] } = $_->[1], next
					if $_->[0] < $max_dist_tail;

				$dist{$max_dist_tail} += $_->[1];
			}
			
			+{
				map {
					"count.puid.".$_."tracks" => $dist{$_}
				} keys %dist
			};
		},
	},

	"count.track.has_puid" => {
		DESC => "Count of tracks with at least one PUID",
		SQL => "SELECT COUNT(DISTINCT track) FROM puidjoin",
	},
	"count.track.Npuids" => {
		DESC => "Distribution of PUIDs per track (varying PUIDs)",
		PREREQ => [qw[ count.track count.track.has_puid ]],
		CALC => sub {
			my ($self, $sql) = @_;

			my $max_dist_tail = 10;

			my $data = $sql->SelectListOfLists(
				"SELECT c, COUNT(*) AS freq
				FROM (
					SELECT track, COUNT(*) AS c
					FROM puidjoin
					GROUP BY track
				) AS t
				GROUP BY c
				",
			);

			my %dist = map { $_ => 0 } 1 .. $max_dist_tail;

			for (@$data)
			{
				$dist{ $_->[0] } = $_->[1], next
					if $_->[0] < $max_dist_tail;

				$dist{$max_dist_tail} += $_->[1];
			}

			$dist{0} = $self->Fetch("count.track")
				- $self->Fetch("count.track.has_puid");
			
			+{
				map {
					"count.track.".$_."puids" => $dist{$_}
				} keys %dist
			};
		},
	},

	"count.moderation.open" => {
		DESC => "Count of open edits",
		CALC => sub {
			my ($self, $sql) = @_;

			my $data = $sql->SelectListOfLists(
				"SELECT status, COUNT(*) FROM moderation_all GROUP BY status",
			);

			my %dist = map { @$_ } @$data;

			+{
				"count.moderation.open"			=> $dist{&ModDefs::STATUS_OPEN}			|| 0,
				"count.moderation.applied"		=> $dist{&ModDefs::STATUS_APPLIED}		|| 0,
				"count.moderation.failedvote"	=> $dist{&ModDefs::STATUS_FAILEDVOTE}	|| 0,
				"count.moderation.faileddep"	=> $dist{&ModDefs::STATUS_FAILEDDEP}	|| 0,
				"count.moderation.error"		=> $dist{&ModDefs::STATUS_ERROR}		|| 0,
				"count.moderation.failedprereq"	=> $dist{&ModDefs::STATUS_FAILEDPREREQ}	|| 0,
				"count.moderation.evalnochange"	=> 0,
				"count.moderation.tobedeleted"	=> $dist{&ModDefs::STATUS_TOBEDELETED}	|| 0,
				"count.moderation.deleted"		=> $dist{&ModDefs::STATUS_DELETED}		|| 0,
			};
		},
	},
	"count.moderation.applied" => {
		DESC => "Count of applied edits",
		PREREQ => [qw[ count.moderation.open ]],
		PREREQ_ONLY => 1,
	},
	"count.moderation.failedvote" => {
		DESC => "Count of edits which were voted down",
		PREREQ => [qw[ count.moderation.open ]],
		PREREQ_ONLY => 1,
	},
	"count.moderation.faileddep" => {
		DESC => "Count of edits which failed their dependency check",
		PREREQ => [qw[ count.moderation.open ]],
		PREREQ_ONLY => 1,
	},
	"count.moderation.error" => {
		DESC => "Count of edits which failed because of an internal error",
		PREREQ => [qw[ count.moderation.open ]],
		PREREQ_ONLY => 1,
	},
	"count.moderation.failedprereq" => {
		DESC => "Count of edits which failed because a prerequisitite moderation failed",
		PREREQ => [qw[ count.moderation.open ]],
		PREREQ_ONLY => 1,
	},
	"count.moderation.evalnochange" => {
		DESC => "Count of evalnochange edits",
		PREREQ => [qw[ count.moderation.open ]],
		PREREQ_ONLY => 1,
	},
	"count.moderation.tobedeleted" => {
		DESC => "Count of edits marked as 'to be deleted'",
		PREREQ => [qw[ count.moderation.open ]],
		PREREQ_ONLY => 1,
	},
	"count.moderation.deleted" => {
		DESC => "Count of deleted edits",
		PREREQ => [qw[ count.moderation.open ]],
		PREREQ_ONLY => 1,
	},

	"count.vote.yes" => {
		DESC => "Count of 'yes' votes",
		CALC => sub {
			my ($self, $sql) = @_;

			my $data = $sql->SelectListOfLists(
				"SELECT vote, COUNT(*) FROM vote_all GROUP BY vote",
			);

			my %dist = map { @$_ } @$data;

			+{
				"count.vote.yes"		=> $dist{&ModDefs::VOTE_YES}	|| 0,
				"count.vote.no"			=> $dist{&ModDefs::VOTE_NO}		|| 0,
				"count.vote.abstain"	=> $dist{&ModDefs::VOTE_ABS}	|| 0,
			};
		},
	},
	"count.vote.no" => {
		DESC => "Count of 'no' votes",
		PREREQ => [qw[ count.vote.yes ]],
		PREREQ_ONLY => 1,
	},
	"count.vote.abstain" => {
		DESC => "Count of 'abstain' votes",
		PREREQ => [qw[ count.vote.yes ]],
		PREREQ_ONLY => 1,
	},

	# count active moderators in last week(?)
	# editing / voting / overall

	"count.moderator.editlastweek" => {
		DESC => "Count of editors who have submitted edits during the last week",
		CALC => sub {
			my ($self, $sql) = @_;

			my $threshold_id = $sql->SelectSingleValue(
				"SELECT MAX(id) FROM moderation_all
				WHERE opentime <= (now() - interval '7 days')",
			);

			# Active voters
			my $voters = $sql->SelectSingleValue(
				"SELECT COUNT(DISTINCT moderator)
				FROM vote_all
				WHERE moderation > ?
				AND moderator != ?",
				$threshold_id,
				&ModDefs::FREEDB_MODERATOR,
			);

			# Editors
			my $editors = $sql->SelectSingleValue(
				"SELECT COUNT(DISTINCT moderator)
				FROM moderation_all
				WHERE id > ?
				AND moderator != ?",
				$threshold_id,
				&ModDefs::FREEDB_MODERATOR,
			);

			# Either
			my $both = $sql->SelectSingleValue(
				"SELECT COUNT(DISTINCT m) FROM (
					SELECT moderator AS m
					FROM moderation_all
					WHERE id > ?
					UNION
					SELECT moderator AS m
					FROM vote_all
					WHERE moderation > ?
				) t WHERE m != ?",
				$threshold_id,
				$threshold_id,
				&ModDefs::FREEDB_MODERATOR,
			);
			
			+{
				"count.moderator.editlastweek"	=> $editors,
				"count.moderator.votelastweek"	=> $voters,
				"count.moderator.activelastweek"=> $both,
			};
		},
	},
	"count.moderator.votelastweek" => {
		DESC => "Count of editors who have voted on edits during the last week",
		PREREQ => [qw[ count.moderator.editlastweek ]],
		PREREQ_ONLY => 1,
	},
	"count.moderator.activelastweek" => {
		DESC => "Count of active editors (editing or voting) during the last week",
		PREREQ => [qw[ count.moderator.editlastweek ]],
		PREREQ_ONLY => 1,
	},

	# To add?
	# - top 10 moderators
	#   - open and accepted last week
	#   - accepted all time
	# Top 10 voters all time

	"count.ar.links" => {
		DESC => "Count of all advanced relationships links",
		CALC => sub {
			my ($self, $sql) = @_;
			my %r;
			$r{'count.ar.links'} = 0;

			require MusicBrainz::Server::LinkEntity;

			for my $t (@{ MusicBrainz::Server::LinkEntity->AllLinkTypes })
			{
				require MusicBrainz::Server::Link;
				my $l = MusicBrainz::Server::Link->new($sql->{DBH}, $t);
				my $n = $l->CountLinksByType;
				$r{"count.ar.links.".$l->Table} = $n;
				$r{'count.ar.links'} += $n;
			}

			return \%r;
		},
	},
	"count.ar.links.l_album_album" => {
		DESC => "Count of release-release advanced relationships links",
		PREREQ => [qw[ count.ar.links ]],
		PREREQ_ONLY => 1,
	},
	"count.ar.links.l_album_artist" => {
		DESC => "Count of release-artist advanced relationships links",
		PREREQ => [qw[ count.ar.links ]],
		PREREQ_ONLY => 1,
	},
	"count.ar.links.l_album_label" => {
		DESC => "Count of release-label advanced relationships links",
		PREREQ => [qw[ count.ar.links ]],
		PREREQ_ONLY => 1,
	},
	"count.ar.links.l_album_track" => {
		DESC => "Count of release-track advanced relationships links",
		PREREQ => [qw[ count.ar.links ]],
		PREREQ_ONLY => 1,
	},
	"count.ar.links.l_album_url" => {
		DESC => "Count of release-URL advanced relationships links",
		PREREQ => [qw[ count.ar.links ]],
		PREREQ_ONLY => 1,
	},
	"count.ar.links.l_artist_artist" => {
		DESC => "Count of artist-artist advanced relationships links",
		PREREQ => [qw[ count.ar.links ]],
		PREREQ_ONLY => 1,
	},
	"count.ar.links.l_artist_label" => {
		DESC => "Count of artist-label advanced relationships links",
		PREREQ => [qw[ count.ar.links ]],
		PREREQ_ONLY => 1,
	},
	"count.ar.links.l_artist_track" => {
		DESC => "Count of artist-track advanced relationships links",
		PREREQ => [qw[ count.ar.links ]],
		PREREQ_ONLY => 1,
	},
	"count.ar.links.l_artist_url" => {
		DESC => "Count of artist-URL advanced relationships links",
		PREREQ => [qw[ count.ar.links ]],
		PREREQ_ONLY => 1,
	},
	"count.ar.links.l_label_label" => {
		DESC => "Count of label-label advanced relationships links",
		PREREQ => [qw[ count.ar.links ]],
		PREREQ_ONLY => 1,
	},
	"count.ar.links.l_label_track" => {
		DESC => "Count of label-track advanced relationships links",
		PREREQ => [qw[ count.ar.links ]],
		PREREQ_ONLY => 1,
	},
	"count.ar.links.l_label_url" => {
		DESC => "Count of label-URL advanced relationships links",
		PREREQ => [qw[ count.ar.links ]],
		PREREQ_ONLY => 1,
	},
	"count.ar.links.l_track_track" => {
		DESC => "Count of track-track advanced relationships links",
		PREREQ => [qw[ count.ar.links ]],
		PREREQ_ONLY => 1,
	},
	"count.ar.links.l_track_url" => {
		DESC => "Count of track-URL advanced relationships links",
		PREREQ => [qw[ count.ar.links ]],
		PREREQ_ONLY => 1,
	},
	"count.ar.links.l_url_url" => {
		DESC => "Count of URL-URL advanced relationships links",
		PREREQ => [qw[ count.ar.links ]],
		PREREQ_ONLY => 1,
	},

	"count.tag" => {
		DESC => "Count of all tags",
		SQL => "SELECT COUNT(*) FROM tag",
	},
	"count.tag.raw.artist" => {
		DESC => "Count of all artist raw tags",
		SQL => "SELECT COUNT(*) FROM artist_tag_raw",
		RAWDATA_DB => 1,
	},
	"count.tag.raw.label" => {
		DESC => "Count of all label raw tags",
		SQL => "SELECT COUNT(*) FROM label_tag_raw",
		RAWDATA_DB => 1,
	},
	"count.tag.raw.release" => {
		DESC => "Count of all release raw tags",
		SQL => "SELECT COUNT(*) FROM release_tag_raw",
		RAWDATA_DB => 1,
	},
	"count.tag.raw.track" => {
		DESC => "Count of all track raw tags",
		SQL => "SELECT COUNT(*) FROM track_tag_raw",
		RAWDATA_DB => 1,
	},
	"count.tag.raw" => {
		DESC => "Count of all raw tags",
		PREREQ => [qw[ count.tag.raw.artist count.tag.raw.label count.tag.raw.release count.tag.raw.track ]],
		CALC => sub {
			my ($self, $sql) = @_;
			return $self->Fetch('count.tag.raw.artist') + 
			       $self->Fetch('count.tag.raw.label') +
			       $self->Fetch('count.tag.raw.release') +
			       $self->Fetch('count.tag.raw.track');
		},
	},

);

sub RecalculateStat
{
	my ($self, $name) = @_;
	my $sql = Sql->new($self->GetDBH);

	my $vertmb = new MusicBrainz;
	$vertmb->Login(db => 'RAWDATA');
	my $vertsql = Sql->new($vertmb->{DBH});

	my $def = $stats{$name}
		or warn("Unknown stat name '$name'"), return;

	return if $def->{PREREQ_ONLY};

	if (my $query = $def->{SQL})
	{
		my $value;
		if ($def->{RAWDATA_DB})
		{
			$value = $vertsql->SelectSingleValue($query);
		}
		else
		{
			$value = $sql->SelectSingleValue($query);
		}
		$self->Update($name, $value);
		return;
	}

	if (my $sub = $def->{CALC})
	{
		my $towrite = $sub->($self, $sql, $vertsql);

		if (ref($towrite) eq "HASH")
		{
			$self->Update(%$towrite);
		} else {
			$self->Update($name => $towrite);
		}
		return;
	}

	warn "Can't calculate $name yet";
}

sub RecalculateAll
{
	my $self = shift;

	my %notdone = %stats;
	my %done;

	for (;;)
	{
		last unless %notdone;

		my $count = 0;

		# Work out which stats from %notdone we can do this time around
		for my $name (sort keys %notdone)
		{
			my $d = $stats{$name}{PREREQ} || [];
			next if grep { $notdone{$_} } @$d;

			# $name has no unsatisfied dependencies.  Let's do it!
			$self->RecalculateStat($name);

			$done{$name} = delete $notdone{$name};
			++$count;
		}

		next if $count;

		my $s = join ", ", keys %notdone;
		die "Failed to solve stats dependencies: circular dependency? ($s)";
	}
}

sub GetStatDescription
{
	my ($self, $name) = @_;
	$stats{$name}{DESC};
}

1;
# vi: set ts=4 sw=4 :
