#!/usr/bin/perl
use strict;
use warnings;
use Net::IMAP::Simple;
use Email::Simple;
use DateTime::Format::Mail;
use Data::Dumper;

sub delete_message($$);

# Configuration
our ($imap_server, $imap_username, $imap_password);
our $imap_inbox = 'INBOX';
our $trash_folder = 'Tidied';
our $search = 'SUBJECT "Cron <root@nas> echo hello" BODY "hello" NOT FLAGGED NOT DELETED';
# Read in config files: system first, then user.
for my $file ("/share/tidy-inbox-imap/defaults.rc",
           "$ENV{HOME}/.tidy-inbox-imaprc",
	   "./.tidy-inbox-imaprc",
    )
{
    unless (my $return = do $file) {
	warn "couldn't parse $file: $@" if $@;
	#warn "couldn't do $file: $!"    unless defined $return;
	#warn "couldn't run $file"       unless $return;
    }
}
 
# RFC2822 date parser
my $date_parser = DateTime::Format::Mail->new( loose => 1 );

# Create the object
my $imap = Net::IMAP::Simple->new($imap_server) ||
   die "Unable to connect to IMAP: ".$Net::IMAP::Simple::errstr."\n";
 
# Log on
if(!$imap->login($imap_username,$imap_password)){
    die "Login failed: $imap->errstr\n";
}

# Select INBOX
unless (my $msgs = $imap->select($imap_inbox)) {
    die "Folder $imap_inbox not found: ".$imap->errstr."\n" unless defined $msgs;
    warn "Folder $imap_inbox is empty. Exiting.\n";
    exit;
}

# Do the search, sorted by date
my @ids = $imap->search($search, 'DATE');
unless (@ids) {
    die $imap->errstr if $imap->waserr;
    # If nothing found just exit silently
    warn "Nothing found in search.\n";
    exit;
}

#print "$#ids messages found\n";
#print "Available server flags: " . join(", ", $imap->flags) . "\n";

if (0) { # Rely on IMAP SEARCH to do the sort
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
    @ids = sort { $message_date{$a} <=> $message_date{$b} } @ids;
}

# Forget about latest message and delete the rest
my $latest = pop @ids;
print "Ignoring most recent message $latest\n";

# Any to delete?
if (@ids) {
    # Make sure the trash folder exists but ignore any error
    $imap->create_mailbox($trash_folder);
    for my $midx ( @ids ) {
	delete_message $midx, $trash_folder;
    }
}

sub delete_message($$) {
    my ($msgnum, $trash) = @_;
    print "Deleting $msgnum\n";
    $imap->copy( $msgnum, $trash ) or die "Copy failed: ".$imap->errstr."\n";
#    $imap->sub_flags( $msgnum, '$label3' ) or die "Setting flag: ".$imap->errstr."\n";
    $imap->delete( $msgnum ) or die "Deleting: ".$imap->errstr."\n";
}
