#!/usr/bin/perl
use strict;
use warnings;
use Getopt::Long;
use Email::Simple;
use Time::ParseDate;
use DateTime::Format::Mail;
use Data::Dumper;

# Using my debugging version of Net::IMAP::Simple cannot be chosen at run time
# So, to use it comment out the 'use Net::IMAP::Simple' and uncomment the require.
use Net::IMAP::Simple;
#require "/home/cobb/Linux/tidy-inbox-imap/Net-IMAP-Simple.pm"; #For debugging Net::IMAP::Simple

#
# Health warning when using Net::IMAP::Simple...
#
# It is a GREAT package for *simple* IMAP operations but it has a big weakness
# in error handling, particularly in the use I make of it here - where you may
# want to do something even after an error has occurred.
#
# For some operations, errors are indicated by returning an empty value,
# for others an undef, for others the setting of $imap->errstr and for others
# the setting of $imap->waserr. It is important to check the right condition
# FOR THE PARTICULAR OPERATION!
#
# In particular, do NOT check waserr except after calls reading flags (msg_flags,
# add_flags, seen, deleted). However, after those calls, DO check waserr
# as imap->errstr may be set even when actually successful!
#
# It is not clear to me that continuing after an error is safe for two reasons:
# (i) It might be that waserr and/or errstr may be set and not cleared by the new call
# (ii) There may be cases where the sub returns without waiting for all
# responses to be received and the dialog with the IMAP server gets out of sync.
# If this turns out to be an issue I will look into killing and restarting
# the connection to the IMAP server after any error.
#

# Global variables
our %config_imap = (); # IMAP settings
our %config_action_defaults = (); # Defaults for subsequent actions
our @config_actions = (); # Array of all actions
our $force_dryrun = 0; # Global dry run override

# Verbosity definitions
our $verbosity_quiet = 0; # warnings and errors only
our $verbosity_normal = 1;
our $verbosity_log = 2; # Log all actions
our $verbosity_info = 3;
our $verbosity_debug = 4;
our $overall_verbosity = $verbosity_normal; # Do not log actions by default

# Command line overrides
# Note: no Pod::Usage documentation because command line options are only used for
# my testing/debugging.
#  --dry - force dry run
#  --verbose increments (or sets) minimum verbosity
#   --verbose=4 - set minimum verbosity to debug
#  --config=<file> - replace (all) default config files with just one specified file
my $override_config;
GetOptions ('dry' => \$force_dryrun,
	    'verbose:+' => \$overall_verbosity,
	    'config=s' => \$override_config,
    );
our $dryrun = $force_dryrun; # May be enabled during certain actions
our $verbosity = $overall_verbosity; # May be increased during certain actions


# Utility routines

# Logging
sub output_normal {
    if ($verbosity >= $verbosity_normal) {print @_};
}
sub output_log {
    if ($verbosity >= $verbosity_log) {print @_};
}
sub output_info {
    if ($verbosity >= $verbosity_info) {print @_};
}
sub output_debug {
    if ($verbosity >= $verbosity_debug) {print @_};
}

# Convert a date specification to an RFC3501 "date-text"
sub date_to_RFC3501($) {
    my ($string) = @_;
    die "date string not specified" unless $string;

    return POSIX::strftime( "%d-%b-%Y",
			    localtime(parsedate($string, {WHOLE => 1, PREFER_PAST => 1}))
	);
}

# Create full search string from parameters
sub build_search($) {
    # The primary purpose of this is to allow us to specify dates in any form acceptable to Time::ParseDate
    my ($action) = @_;
    my $before='';
    my $since='';

    $before = 'BEFORE '.date_to_RFC3501($action->{before}).' ' if $action->{before};
    $since = 'SINCE '.date_to_RFC3501($action->{since}).' ' if $action->{since};
    return $before.$since.$action->{search};
}

sub do_search($$$) {
    my ($imap, $search, $sort) = @_;
    output_debug("do_search2=".$search."\n");
    # Note: search doesn't usefully report errors, so we can't normally distinguish no results from an error
    my @ids = $imap->search($search, $sort);
    die "Search ".$search." failed: ", ($imap->errstr || '') if $imap->waserr;
    return @ids
}

sub delete_message($$$) {
    my ($imap, $msgnum, $trash) = @_;
    $imap->copy( $msgnum, $trash )
	or ( ($imap->errstr =~ /\[TRYCREATE\]/i) and $imap->create_mailbox($trash) and $imap->copy( $msgnum, $trash ) )
	or die "Copy failed: ", ($imap->errstr || '');
    $imap->delete( $msgnum ) or die "Delete failed: ", ($imap->errstr || '');
}

# Actions

# action_delete handles both dedup and delete
sub action_delete($$) {
    my ($imap, $action) = (@_);
    
    # Select INBOX
    unless (my $msgs = $imap->select($action->{inbox})) {
	die "Folder $action->{inbox} not found: " unless defined $msgs;
	warn "Folder $action->{inbox} is empty.\n", ($imap->errstr || '');
	return;
    }

    # Do the search, sorted by date
    my $search = build_search($action);
    my @ids = do_search($imap, $search, $action->{order});

    # If nothing found just exit
    unless (@ids) {
	output_info("Nothing found in search.\n");
	return;
    }

    if ($action->{filter}) {
	@ids = $action->{filter}($imap, @ids);
	# If nothing remaining just exit
	return unless (@ids);
    }

    output_debug(@ids." messages found\n");
    output_debug("Available server flags: " . join(", ", $imap->flags) . "\n");

    # Forget about latest message and delete the rest
    if ($action->{keep} && $action->{keep} > 0) {
	for ( my $i = $action->{keep} ; $i ; $i-- ) {
	    my $latest = pop @ids;
	    last unless $latest;
	    output_info("Ignoring message $latest\n");
	}
    }
    if ($action->{keep} && $action->{keep} < 0) {
	for ( my $i = - $action->{keep} ; $i ; $i-- ) {
	    my $latest = shift @ids;
	    last unless $latest;
	    output_info("Ignoring message $latest\n");
	}
    }

    # Any to delete?
    if (@ids) {
	for my $midx ( @ids ) {
	    output_log("DRY RUN: ") if $dryrun;
	    output_log("Deleting $midx\n");
	    delete_message $imap, $midx, $action->{trash} unless $dryrun;
	}
    }
    
}

# action_check handles check, list and flag (list and flag use specific 'check' functions)
sub action_check($$) {
    my ($imap, $action) = (@_);

    # Select INBOX
    unless (my $msgs = $imap->select($action->{inbox})) {
	die "Folder $action->{inbox} not found: ", ($imap->errstr || '') unless defined $msgs;
	warn "Folder $action->{inbox} is empty.\n";
	return;
    }

    # Do the search, sorted by date
    my $search = build_search($action);
    my @ids = do_search($imap, $search, $action->{order});

    if ($action->{filter} && @ids) {
	@ids = $action->{filter}($imap, $action->{param}, @ids);
    }

    output_debug(@ids." messages found\n");

    # Do checks
    my $check_ok = 1;
    my $warning;

    ($check_ok, $warning) = $action->{check}($imap, $action->{param}, @ids) if $action->{check};
    $check_ok = 0 if $action->{min} && @ids < $action->{min};
    $check_ok = 0 if $action->{max} && @ids > $action->{max};

    unless ($check_ok) {
	$warning = $warning || $action->{warning};
	output_normal(sprintf($warning, scalar @ids)."\n");
    }

}
# Default 'list items' routine. Displays some message info.
# At 'info' verbosity level, displays all message headers
sub list_items($$@) {
    my ($imap, $param, @ids) = (@_);

    for my $midx ( @ids ) {
	output_normal("Message: $midx\n");
	output_info("Size: ".$imap->list($midx)." bytes)\n");
	my $flags = $imap->msg_flags($midx);
	if ($flags) {output_info("Flags: ".$flags."\n");} else {output_info("Flags: ".$imap->errstr."\n");};
	my $message = $imap->fetch($midx) or die 'IMAP fetch failed: ', ($imap->errstr || '');
	$message = "$message"; # force stringification
	output_debug(Dumper \$message);
	my $email = Email::Simple->new($message);
	output_normal("Date: ".$email->header_raw('Date')."\n");
	output_normal("From: ".$email->header_raw('From')."\n");
	output_normal("To: ".$email->header_raw('To')."\n");
	output_normal("Subject: ".$email->header_raw('Subject')."\n");

	# Headers
	my @header_names = $email->header_names;
	for my $hdr ( @header_names ) {
	    next if $hdr eq "From" || $hdr eq "To" || $hdr eq "Subject" || $hdr eq "Date";
	    output_info($hdr.": ".$email->header_raw($hdr)."\n");
	}

	output_info("\n");
    }

    return 1;
}

# "Check" function to handle flag action
sub add_flag($$@) {
    my ($imap, $new_flag, @ids) = (@_);

    for my $midx ( @ids ) {
	output_info("Message: $midx\n");
	output_debug("Size: ".$imap->list($midx)." bytes\n");
	# NOTE: Unfortunately (and arguably a bug), the Net::IMAP::Simple flags routines set errstr unconditionally
	# and so it is necessary to test 'waserr' instead. Note no other routines use waserr.
	my $flags = $imap->msg_flags($midx);
	die "Current flags ".$midx." failed: ".$imap->errstr."\n" if $imap->waserr;
	output_info("Current flags: ".$flags."\n");

	output_log("DRY RUN: ") if $dryrun;
	output_log("Message $midx add flag $new_flag\n");
	unless ($dryrun) {
	    $imap->add_flags( $midx, $new_flag );
	    die "add_flags ".$midx." failed: ".$imap->errstr."\n" if $imap->waserr;
	}

	$flags = $imap->msg_flags($midx);
	if ($flags) {output_info("New flags: ".$flags."\n");} else {output_info("New flags error: ".$imap->errstr."\n");};

	my $message = $imap->fetch($midx) or die $imap->errstr;
	$message = "$message"; # force stringification
	output_debug(Dumper \$message);
    }

    return 1;
}

# Filters

# Sample filter, although sorting by date is built-in to the search and is the default
sub filter_sort_by_date($$@) {
    my ($imap, $param, @ids) = (@_);
    
    # RFC2822 date parser
    my $date_parser = DateTime::Format::Mail->new( loose => 1 );

    # Messages and dates
    my %message_date;

    for my $midx ( @ids ) {
	my $message = $imap->fetch($midx) or die $imap->errstr;
	$message = "$message"; # force stringification
	output_debug(Dumper \$message);
	my $email = Email::Simple->new($message);
	my $datehdr = $email->header("Date");
	my $datetime = $date_parser->parse_datetime($datehdr);
	$message_date{$midx} = $datetime;
	output_debug("$midx - $datehdr\n");
    }

    # Sort by date
    return sort { $message_date{$a} <=> $message_date{$b} } @ids;
}

# Configuration

# Set IMAP settings
sub config_imap (@) {
    # Merge specified values into %config_imap
    %config_imap = (%config_imap , @_);
}

# Set action defaults
sub config_action_defaults (@) {
    # Merge specified values into %config_action_defaults
    %config_action_defaults = (%config_action_defaults , @_);
}

sub add_config_action ($) {
    # Add a config action hash reference to the list of actions to perform
    push @config_actions, @_;
}
# Add dedup action
sub config_action_dedup (@) {
    my $action = {
	keep => 1, # Can be overriden by defaults
	order => 'DATE', # Can be overriden by defaults
	%config_action_defaults,
	action => \&action_delete,
	@_,
    };
    if ($action->{param}) {die "Param can only be specified if filter, check or action are specified" unless $action->{filter} || $action->{check} || $action->{list};}
    die "Dedup action requires search to be specified" unless $action->{search};
    warn "Dedup actions with keep=>0 should be written as delete actions" if $action->{keep} == 0;
    add_config_action $action;
}
# Add delete action
sub config_action_delete (@) {
    my $action = {
	%config_action_defaults,
	keep => 0, # Overrides defaults
	action => \&action_delete,
	@_,
    };
    if ($action->{param}) {die "Param can only be specified if filter, check or action are specified" unless $action->{filter} || $action->{check} || $action->{list};}
    die "Delete action requires search to be specified" unless $action->{search};
    warn "Delete actions with keep should be written as dedup actions" if $action->{keep};
    add_config_action $action;
}
# Add expunge action
sub config_action_expunge (@) {
     my $action = {
	%config_action_defaults,
	action => \&action_expunge,
	@_,
    };
    if ($action->{param}) {die "Param can only be specified if filter, check or action are specified" unless $action->{filter} || $action->{check} || $action->{list};}
    die "Expunge action requires folder to be specified" unless $action->{folder};
    add_config_action $action;
}
# Add list action
sub config_action_list (@) {
    my $action = {
	%config_action_defaults,
	list => \&list_items,
	action => \&action_check,
	@_,
    };
    die "List action requires search to be specified" unless $action->{search};
    die "List action must not include min, max or check" if $action->{min} || $action->{max} || $action->{check};
    if ($action->{param}) {die "Param can only be specified if filter, check or action are specified" unless $action->{filter} || $action->{check} || $action->{list};}
    # action_check needs the 'list' function to actually be stored as a 'check' function
    $action->{check} = $action->{list};
    add_config_action $action;
}
# Add add flag action
sub config_action_flag (@) {
    my $action = {
	%config_action_defaults,
	check => \&add_flag,
	action => \&action_check,
	@_,
    };
    die "Flag action requires search to be specified" unless $action->{search};
    die "Flag action must not include min or max" if $action->{min} || $action->{max};
    die "Flag action must not include param or list (use List action if these are needed)" if $action->{param} || $action->{list};
    # add_flag needs the 'flag' to actually be stored as the 'param'
    $action->{param} = $action->{flag};
    add_config_action $action;
}
# Add null action
sub config_action_null (@) {
    my $action = {
	%config_action_defaults,
	action => undef,
	@_,
    };
    if ($action->{param}) {die "Param can only be specified if filter, check or action are specified" unless $action->{filter} || $action->{check} || $action->{list};}
    add_config_action $action;
}
# Add check action
sub config_action_check (@) {
    my $action = {
	%config_action_defaults,
	action => \&action_check,
	@_,
    };
    die "Check action requires min or max to be specified" unless $action->{min} || $action->{max};
    die "Check action requires search to be specified" unless $action->{search};
    if ($action->{param}) {die "Param can only be specified if filter, check or action are specified" unless $action->{filter} || $action->{check} || $action->{list};}
    add_config_action $action;
}


# Builtin defaults
config_action_defaults (
    folder => 'INBOX',
    trash => 'Trash',
    order => 'DATE',
    warning => 'Check failed: %d messages match search',
    # dryrun => 0,
    # keep => 0,
    # search => '',
    # comment => '',
    # filter => undef,
    # since => undef,
    # before => undef,
    # min => undef,
    # max => undef,
    # param => undef,
    );
# Allows turning on Net::IMAP::Simple debug logging in config files
my $imap_debug = 0;

# Read in config files: system first, then user.
# Unless overriden by --config
my @configfiles = (defined $override_config) ? $override_config :
    ("/usr/share/tidy-inbox-imap/defaults.rc",
     "$ENV{HOME}/.tidy-inbox-imaprc.imap-settings",
     "$ENV{HOME}/.tidy-inbox-imaprc",
     "./.tidy-inbox-imap" );
for my $file (@configfiles)
{
    unless (my $return = do $file) {
	# Note: file errors are fatal if --config has been specified
	if (defined $override_config) {
	    die "couldn't parse $file: $@" if $@;
	    die "couldn't do $file: $!" unless defined $return;
	} else {
	    warn "couldn't parse $file: $@" if $@;
	    # warn "couldn't do $file: $!" unless defined $return;
	}
	# warn "couldn't run $file" unless $return;
    }
}
 
# IMAP connect
my $imap = Net::IMAP::Simple->new($config_imap{server},
				  find_ssl_defaults => 1,
				  debug => $imap_debug) ||
   die "Unable to connect to IMAP: ".$Net::IMAP::Simple::errstr."\n";
 
# Log on
if ($config_imap{username}) {
    $imap->login($config_imap{username},$config_imap{password}) or die "Login failed: $imap->errstr\n";
}

# Do the actions
for my $action (@config_actions) {
    $verbosity = $overall_verbosity; # Reset transient verbosity
    $verbosity = $action->{verbose} if $action->{verbose} && $action->{verbose} > $verbosity;
    $dryrun = $action->{dryrun} || $force_dryrun;
    
    output_normal($action->{comment}."\n") if $action->{comment};

    $action->{action}($imap, $action) if $action->{action};
}
