# tidy-inbox-imap
Tidy up mail inbox with simple rules - imap version

This script accesses the user's mail Inbox and performs various tidying actions:

 * Remove duplicates of mails with specific subjects, keeping just the latest
 * Expunge

### Rationale

There are various ways to automate mail tidying, including sieve processing and client-based rules.
They all have advantages and disadvanatages and I use all three.
Sieve is great for efficiently directing and filtering mail as it is delivered, but it does not handle subsequent
processing (like deleting an old email when a replacement arrives).
Client rules have access to client-side folders as well as IMAP folders but are normally fairly limited
without powerful scripting and are also often triggered only by arrival of new mail.

This tool is less efficient as it ends up manipulating messages over IMAP, and it only has access to the
IMAP server folders, but it can run at any time and includes powerful scripting.

## Dedup

The mailbox is searched for all messages matching certain critieria.
The most recent message(s) are kept, the older messages are deleted.
Deleted messages are actually moved to a specified Trash folder and then marked deleted.

Parameters:
 * `search` - IMAP search to use for messages - **no default**
 * `folder` - folder to search - **default:** *INBOX*
 * `trash` - folder to move deleted messages to - **default:** *Trash*
 * `dryrun` - do not actually perform delete action - **default:** *0*
 * `keep` - number of messages to keep; +N means keep most recent N, -N means keep oldest N - **default** *+1*
 * `order` - ordering for search results - **default:** *DATE*
 * `comment` - text to print when starting this action - **default:** *empty*
 * `filter` - perl subroutine reference to filter selected messages - **default:** *none*

## Configuration

Perl files for configuration are searched for and all loaded, in order, from:

```
/share/tidy-inbox-imap/defaults.rc
$ENV{HOME}/.tidy-inbox-imaprc
./.tidy-inbox-imaprc
```

The configuration files are perl scripts can should call the
config procedures:
* config_imap
* config_action_defaults
* config_action_dedup
* *config_action_delete*
* *config_action_expunge*
* *config_action_list*

Note: the script will execute the actions in the order they are defined in the config files.

### config_imap
This is used to specify the connection to the IMAP server.
It must be called somewhere in one of the configuration files and must at least specify the server name.

* `server` - host name of IMAP server - **no default**
* `username` - username for IMAP login - **no default** - if not specified, no login is attempted (this is unlikely to work)
* `password` - password for IMAP login - **no default** - must be specified if username is specified

### config_action_defaults
This is used to set default parameters for all the actions.
An example is to set the trash folder to something other than the built-in default (Trash).

Each call to this procedure merges the specified values into the defaults (replacing any existing
default value for the same parameter).
These defaults will be applied to any later call to the action configurations.

### config_action_dedup
Add a "dedup" action.
See description of the action and its parameters above.

### Searches
Most actions require an IMAP RFC 3501 search string to specify the messages to be acted upon.
An example is `SUBJECT "Cron <root@nas> echo hello" BODY "hello" NOT FLAGGED NOT DELETED`.

It is recommended to include `NOT DELETED` as previously deleted messages may not have been expunged when the
script runs.

I also normally include `NOT FLAGGED` so that I can manually exclude messages from
script processing by marking them with a flag in my mail client (a star in thunderbird).

### Example
An example config file can be found as `tidy-inbox-imaprc.example` in the git repository.

## Filter

A filter procedure can be used to remove message ids from processing in the action.
It has to be a perl subroutine which accepts a (scalar) reference to the Net::IMAP::Simple
object for the connection followed by the list of message ids.
It must return the list of message ids to be processed, even if it is unchanged.

An example filter procedure is `filter_sort_by_date` in the main script source.

# ToDo

 * Expunge
 * Command line configuration
 * Add additional tidying options: not just removing duplicates
 