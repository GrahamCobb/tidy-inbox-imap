#!/usr/bin/perl
use strict;
use warnings;
use Net::IMAP::Simple;
use Email::Simple;
use Time::ParseDate;
use DateTime::Format::Mail;
use Data::Dumper;

# Global variables
our %config_imap = (); # IMAP settings
our %config_action_defaults = (); # Defaults for subsequent actions
our @config_actions = (); # Array of all actions
our $force_dryrun = 0; # Global dry run override

# Utility routines

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
    print $search."\n";
    my @ids = $imap->search($search, $sort);
    die "Search failed: ".$imap->errstr."\n" if $imap->waserr || $imap->errstr;
    return @ids
}

sub delete_message($$$) {
    my ($imap, $msgnum, $trash) = @_;
    $imap->copy( $msgnum, $trash )
	or ( ($imap->errstr =~ /\[TRYCREATE\]/i) and $imap->create_mailbox($trash) and $imap->copy( $msgnum, $trash ) )
	or die "Copy failed: ".$imap->errstr."\n";
    $imap->delete( $msgnum ) or die "Delete failed: ".$imap->errstr."\n";
}

# Actions

# action_delete handles both dedup and delete
sub action_delete($$) {
    my ($imap, $action) = (@_);

    if ($action->{comment}) { print $action->{comment}."\n"; }
    
    # Select INBOX
    unless (my $msgs = $imap->select($action->{inbox})) {
	die "Folder $action->{inbox} not found: ".$imap->errstr."\n" unless defined $msgs;
	warn "Folder $action->{inbox} is empty.\n";
	return;
    }

    # Do the search, sorted by date
    my $search = build_search($action);
    my @ids = do_search($imap, $search, $action->{order});

    # If nothing found just exit
    unless (@ids) {
	print "Nothing found in search.\n";
	return;
    }

    if ($action->{filter}) {
	@ids = $action->{filter}($imap, @ids);
	# If nothing found just exit
	return unless (@ids);
    }

    #print @ids." messages found\n";
    #print "Available server flags: " . join(", ", $imap->flags) . "\n";

    # Forget about latest message and delete the rest
    if ($action->{keep} && $action->{keep} > 0) {
	for ( my $i = $action->{keep} ; $i ; $i-- ) {
	    my $latest = pop @ids;
	    last unless $latest;
	    print "Ignoring message $latest\n";
	}
    }
    if ($action->{keep} && $action->{keep} < 0) {
	for ( my $i = - $action->{keep} ; $i ; $i-- ) {
	    my $latest = shift @ids;
	    last unless $latest;
	    print "Ignoring message $latest\n";
	}
    }

    # Any to delete?
    if (@ids) {
	for my $midx ( @ids ) {
	    if ($force_dryrun || $action->{dryrun}) {print "DRY RUN: ";}
	    print "Deleting $midx\n";
	    delete_message $imap, $midx, $action->{trash} unless $force_dryrun || $action->{dryrun};
	}
    }
    
}

# Filters

# Sample filter, although sorting by date is built-in to the search and is the default
sub filter_sort_by_date($@) {
    my ($imap, @ids) = (@_);
    
    # RFC2822 date parser
    my $date_parser = DateTime::Format::Mail->new( loose => 1 );

    # Messages and dates
    my %message_date;

    for my $midx ( @ids ) {
	my $message = $imap->fetch($midx) or die $imap->errstr;
	$message = "$message"; # force stringification
	#print Dumper \$message;
	my $email = Email::Simple->new($message);
	my $datehdr = $email->header("Date");
	my $datetime = $date_parser->parse_datetime($datehdr);
	$message_date{$midx} = $datetime;
	print "$midx - $datehdr\n";
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
    die "Expunge action requires folder to be specified" unless $action->{folder};
    add_config_action $action;
}
# Add list action
sub config_action_list (@) {
    my $action = {
	%config_action_defaults,
	action => \&action_list,
	@_,
    };
    die "List action requires search to be specified" unless $action->{search};
    add_config_action $action;
}

# Builtin defaults
config_action_defaults (
    folder => 'INBOX',
    trash => 'Trash',
    order => 'DATE',
    # dryrun => 0,
    # keep => 0,
    # search => '',
    # comment => '',
    # filter -> undef,
    );

# Read in config files: system first, then user.
for my $file ("/share/tidy-inbox-imap/defaults.rc",
           "$ENV{HOME}/.tidy-inbox-imaprc",
	   "./.tidy-inbox-imap",
    )
{
    unless (my $return = do $file) {
	warn "couldn't parse $file: $@" if $@;
	#warn "couldn't do $file: $!"    unless defined $return;
	#warn "couldn't run $file"       unless $return;
    }
}
 
# IMAP connect
my $imap = Net::IMAP::Simple->new($config_imap{server}) ||
   die "Unable to connect to IMAP: ".$Net::IMAP::Simple::errstr."\n";
 
# Log on
if ($config_imap{username}) {
    $imap->login($config_imap{username},$config_imap{password}) or die "Login failed: $imap->errstr\n";
}

# Do the actions
for my $action (@config_actions) {
    $action->{action}($imap, $action);
}
