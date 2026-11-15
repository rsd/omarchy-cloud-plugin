# Glossary

The core words (**remote**, **mount**, **mount folder**, **offline folder**,
**backup**, **panel**, **installed parts**) are defined in the
[README](../README.md#words-used-in-these-docs). The words below are the other ones
you may meet, in alphabetical order.

## bisync

`rclone bisync` is rclone's two-way sync. It remembers what both folders
looked like after the last sync, and copies changes both ways. Offline folders use
it.

## Cache

A copy of data kept nearby so it is quick to use. See
[VFS cache](#vfs-cache).

## Conflict copy

What is left when the same file changed on both sides between two
syncs: `X.conflict1`, `X.conflict2`. See
[offline-folders.md](offline-folders.md#conflict-copies).

## Drop-in

A small file in a `*.d/` folder that changes one setting of a systemd
unit for one instance. `setup` writes them.

## .env file

A plain text file (`~/.config/rclone-mount/<remote>.env`) of
`NAME=value` lines that holds a remote's cache and polling settings. systemd reads it
as an "environment file".

## Floating terminal

The small terminal window that opens on top of your desktop
when you click **Configure…** or **Set up…**.

## FUSE

"filesystem in userspace", the part of Linux that lets a normal program
(rclone) provide a folder. `fuse3` is its package; `fusermount3` unmounts a FUSE
folder. A "FUSE mount" is any such folder, not only this plugin's.

## Instance

One remote, offline folder or backup, as a systemd unit: the part after
the `@`, e.g. `rclone-mount@gdrive.service`.

## Journal

The log systemd keeps for each unit. `journalctl --user -u <unit>` reads
it; the app's Maintenance section shows it too.

## Lazy unmount

A lazy unmount (`fusermount3 -uz`) detaches a mount now even if programs still have
files open on it. It is how the mount service stops, so a stop never hangs.

## Link (symlink)

A shortcut that points to another folder or file. `~/Cloud/<remote>`
is a link to the mount.

## Mount root

Another name for the mount folder, used in the installer, the panel's
messages and the setting `OMARCHY_CLOUD_ROOT`.

## OAuth / sign in

The way Google, Microsoft and others let a program use your
account without knowing your password. You sign in on the provider's own web page in
your browser and click **Allow**; the provider gives rclone a "token". A **client**
is the application identity (client id and secret) rclone presents to the provider.

## Pair / job

The names used in file and unit names for an offline folder
(`rclone-bisync@<pair>`) and a backup (`rclone-backup@<job>`).

## rclone

The command-line program that talks to cloud services.
<https://rclone.org>

## rclone config

Rclone's own question screen, where you add a remote or sign in
again. The app opens it for you.

## Shared Drive (Team Drive)

A Google Drive that belongs to an organisation rather
than to one person.

## Sync

Making two folders match, by copying changes from one to the other.

## sudo

Runs one command as the computer's administrator and asks for your
password. Nothing appears while you type the password. The plugin uses it only for the
one-time mount folder command, which you run yourself.

## systemd

The part of Linux that starts and supervises services. A **user unit**
runs as you in your login session. A **unit** is one service, timer or watch
definition; a **timer** runs another unit on a schedule; a **path unit** watches a
folder and runs another unit when it changes. The plugin uses `systemctl --user` to
control them.

## Terminal

A window where you type commands. On Omarchy, `Super` + `Enter` opens
one.

## TUI

A "terminal user interface": a program that runs inside a terminal and is
used with the keyboard. The Omarchy Cloud app is one.

## VFS cache

Rclone's local disk cache for a mount (`~/.cache/rclone/vfs/<remote>`):
the parts of files you opened and the uploads still on their way. Uploads are held
there for a moment ("write-back") before they go to the cloud; those are the "pending
uploads" the app counts before an unmount.
