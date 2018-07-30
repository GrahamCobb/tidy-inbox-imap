# tidy-inbox-imap
Tidy up mail inbox with simple rules - imap version

This script accesses the user's mail Inbox and performs various tidying actions:

 * Initially this script just removes duplicates of mails with specific subjects, keeping the latest

## Dedup

The mailbox is searched for all messages matching certain critieria.
The most recent message is kept, the older messages are deleted.

Deleted messages are actually moved to a specified Trash folder and then marked deleted.

Initially, the criterion is limited to:
```
Specified Subject (no wildcards or regular expression) AND NOT \Flagged
```

## Configuration

Perl files for configuration are loaded, in order, from:

```
/share/tidy-inbox-imap/defaults.rc
$ENV{HOME}/.tidy-inbox-imaprc
./.tidy-inbox-imaprc
```

Between them, these files should set the following variables:
```
$imap_server -- no default
$imap_username -- no default
$imap_password -- no default
$imap_inbox -- default INBOX
$trash_folder -- default Tidied
$search -- RFC 3501 search string, default 'SUBJECT "Cron <root@nas> echo hello" BODY "hello" NOT FLAGGED NOT DELETED'
``` 

# ToDo

 * Add expunge
 * More than one criterion per run
 * Better configuration (command line?)
 * Allow different Trash folders for each operation
 * Add additional tidying options: not just removing duplicates
 