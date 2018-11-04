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

## Actions

All (unless specified) actions support the following parameters:

Parameters:
 * `search` - IMAP search to use for messages (see Search below) - **no default**
 * `before` - Date for IMAP BEFORE search (see Search below) - **default:** *none*
 * `since` - Date for IMAP SINCE search (see Search below) - **default:** *none*
 * `folder` - folder to search - **default:** *INBOX*
 * `trash` - folder to move deleted messages to - **default:** *Trash*
 * `dryrun` - do not actually perform delete action - **default:** *0*
 * `keep` - (Dedup only) number of messages to keep; +N means keep most recent N, -N means keep oldest N - **default:** *+1*
 * `order` - ordering for search results - **default:** *DATE*
 * `comment` - text to print when starting this action - **default:** *none*
 * `filter` - perl subroutine reference to filter selected messages - **default:** *none*
 * `min` - (Check only) minimum number of messages expected in check - **default:** *none*
 * `max` - (Check only) maximum number of messages expected in check - **default:** *none*
 * `warning` - (Check only) message to display if check fails - **default:** *Check failed: %d messages match search*
 * `check` - (Check only) perl subroutine reference to determine if messages pass check - **default:** *none*
 * `list` - (List only) perl subroutine reference to display message info - **default:** *\&list-items*
 * `verbose` - verbosity to use during this action (0 = quiet (warnings and errors only), 1 = normal, 2 = log (all actions), 3 = info, 4 = debug) - **default:** *1*

### Dedup

The mailbox is searched for all messages matching certain critieria (search and filter).
The most recent message(s) are kept, the older messages are deleted.
Deleted messages are actually moved to a specified Trash folder and then marked deleted.

### Delete

The mailbox is searched for all messages matching certain critieria (search and filter), which are then deleted.
Deleted messages are actually moved to a specified Trash folder and then marked deleted.

### Null

Does nothing (except printing the comment).

### Check

The mailbox is searched for all messages matching certain critieria (search and filter).

A check procedure can be specified to allow perl code to determine if the check passes.
This has to be a perl subroutine which accepts a (scalar) reference to the Net::IMAP::Simple
object for the connection followed by the list of message ids (this is the same arguments as a filter procedure).
It must return a true/false value to indicate whether the test passes.
This can be a scalar or the first element of a list.
If a list, the second element must be the desired warning message (this will replace the message specified
in the configuration).

All the specified checks are applied:
 * `check` - the specified subroutine determines if the messages pass the checks
 * `min` - fails if the number of messages is below the specified value
 * `max` - fails if the number of messages is above the specified value

If the check passes nothing happens.
If it fails, the warning message is printed (using it as a printf format, with the number of messages as the value).

### List

The mailbox is searched for all messages matching certain critieria (search and filter).
Matching messages have some basic information (message id, date, from, to and subject) displayed
(more information is shown at verbosity level "info").

It is possible to specify your own perl procedure to display custom information.
This has to be a perl subroutine which accepts a (scalar) reference to the Net::IMAP::Simple
object for the connection followed by the list of message ids (this is the same arguments as a check procedure).
The subroutine MUST return a scalar true value (1 is recommended).

There is nothing to stop the list procedure from modifying the message, and this may be desired.
However, the list action will always call the list procedure even if `dryrun` is specified.
If the list procedure intends to make changes it should check the $dryrun variable.

Note: the subroutine `list_items` is the default listing subroutine and may be useful as an example.

## Configuration

Perl files for configuration are searched for and all loaded, in order, from:

```
/usr/share/tidy-inbox-imap/defaults.rc
$ENV{HOME}/.tidy-inbox-imaprc.imap-settings
$ENV{HOME}/.tidy-inbox-imaprc
./.tidy-inbox-imap
```

The configuration files are perl scripts and can call the
config procedures:
* config_imap
* config_action_defaults
* config_action_dedup
* config_action_delete
* config_action_null
* config_action_check
* *config_action_list
* *config_action_expunge*

Note: the script will execute the actions in the order they are defined in the config files.

### config_imap
This is used to specify the connection to the IMAP server.
It **must** be called somewhere in one of the configuration files and must at least specify the server name.

* `server` - host name of IMAP server - **no default**
* `username` - username for IMAP login - **no default** - if not specified, no login is attempted (this is unlikely to work)
* `password` - password for IMAP login - **no default** - must be specified if username is specified

### config_action_defaults
This is used to set default parameters for subsequent actions.
An example is to set the trash folder to something other than the built-in default (Trash).

Each call to this procedure merges the specified values into the defaults (replacing any existing
default value for the same parameter).
These defaults will be applied to any later call to the action configurations.

### Example
An example config file can be found as `tidy-inbox-imaprc.example` in the git repository.

## Searches
Most actions require an IMAP RFC 3501 search string to specify the messages to be acted upon.
An example is `SUBJECT "Cron <root@nas> echo hello" BODY "hello" NOT FLAGGED NOT DELETED`.

It is recommended to include `NOT DELETED` as previously deleted messages may not have been expunged when the
script runs.

I also normally include `NOT FLAGGED` so that I can manually exclude messages from
script processing by marking them with a flag in my mail client (a star in thunderbird).

## Search

Search strings should be specified in the syntax defined in the IMAP RFC 3501
(or any restricted or extended syntax supoported by your server).

### Dates
RFC 3501 allows dates to be specified in BEFORE, ON, SINCE, SENTBEFORE, SENTON and SENTSINCE clauses.

The RFC 3501 format for dates is quite restrictive: just DD-MMM-YYYY.
However, of course, the full power of perl is available for formatting dates.
For example, the following would be a valid `search =>` specification:
```
search => 'ON ' . POSIX::strftime( "%d-%b-%Y", localtime( ( time() - ( 24 * 60 * 60 ) ) ) ) . ' SUBJECT "test"'
```
Unfortunately, that calculation for yesterday does not correctly handle daylight saving time!
For convenience, a utility function `date_to_RFC3501` is provided which converts any date string
acceptable to Time::ParseDate into the RFC 3501 format. This includes strings such as "today", "2 days ago",
"last monday". So, a more correct search specification would be:
```
search => 'ON ' . date_to_RFC3501('yesterday') . ' SUBJECT "test"'
```

As BEFORE and SINCE are so common, they can be specified directly as action parameters (for example `since => 'yesterday'`).
The value for the parameter is passed to date_to_RFC3501 and the result is combined with either `BEFORE` or `SINCE`
and added to **the front of the search string**. If the value needs to be inserted into the string somewhere else
(for example in a `NOT` or `OR` clause or in parentheses) then the string must be constructed in perl as in the example above.

## Filter

A filter procedure can be specified to remove message ids from processing during the action.
It has to be a perl subroutine which accepts a (scalar) reference to the Net::IMAP::Simple
object for the connection followed by the list of message ids.
It must return the list of message ids to be processed, even if it is unchanged.

An example filter procedure is `filter_sort_by_date` in the main script source.
Note: this specific filter is not normally needed as the default search order is by date
but the code may be a useful example.

## ToDo

 * Expunge
 * Command line configuration
 * List action
 * Logging
 * Other actions
 