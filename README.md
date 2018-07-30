# tidy-inbox-imap
Tidy up mail inbox with simple rules - imap version

This script accesses the user's mail Inbox and performs various tidying actions:

 * Initially this script just removes duplicates of mails with specific subjects, keeping the latest

## Dedup

The mailbox is searched for all messages matching certain critieria.
The most recent message is kept, the older messages are deleted.

Deleted messages are actually moved to a specified Trash folder.

Initially, the criterion is limited to:
```
Specified Subject (no wildcards or regular expression) AND NOT Starred
```

# ToDo

 * Configurable without editing script
 * Allow different Trash folders for each operation
 * Allow for more than just "specific subject, no star" as way to specify duplicates
 * Do more than just remove duplicates
 