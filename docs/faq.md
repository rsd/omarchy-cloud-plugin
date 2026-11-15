# Frequently asked questions

## Will it delete my files?

- Adding, mounting, removing and unmounting never delete your cloud files.
- **Removing** a remote, an offline folder or a backup in the app never deletes any
  files: not yours, not the cloud's, not the backup copies.
- A **mount** shows your cloud files as a folder. Deleting a file in that folder
  deletes it in the cloud, as it would in the Google Drive website.
- An **offline folder** syncs both ways, so a file you delete on one side is deleted
  on the other, as with any sync tool. If you only want copies you can go back to,
  use a backup.
- A **backup** (dated copies of important files) only downloads. It deletes only its own old dated copies, when there
  are more than "keep".
- If the same file changes on both sides, both versions are kept and you are told.

## Is it safe to give it my Google account?

You sign in to Google in your browser, with Google's own page; this plugin never
sees your password. The sign-in token is kept by rclone, in its own configuration on
your computer. The plugin does not read it (the only exception is the optional
client id and secret you can set with `g`, see
[remotes.md](remotes.md#your-own-google-drive-client-usually-not-needed)). You can
remove the access any time at <https://myaccount.google.com/permissions>.

## Do I need to know rclone?

No. You need it installed. Adding a remote uses rclone's own question screen; the
[walkthrough](remotes.md#add-google-drive-step-by-step) gives the answers. Learn more
about rclone at <https://rclone.org>.

## Does installing turn anything on?

No. Installing copies files and sets up the mount folder. Nothing is mounted, synced
or scheduled until you add and switch it on in the app.

## Why does the installer ask me to run a `sudo` command?

Your cloud drives appear in a folder outside your home folder, `/mnt/cloud` by
default, and `/mnt` belongs to the system. You create the folder once, with one
command that makes you its owner. The installer never runs `sudo` itself. Steps:
[mount-folder.md](mount-folder.md#create-the-mount-folder-step-by-step).

## Why are my cloud drives not inside my home folder?

So search and backup tools do not crawl a slow or huge cloud drive. `~/Cloud/<remote>`
is a shortcut to the real mount, so you still find your files there. For the same
reason the mount folder cannot be a link that leads into your home folder. More:
[mount-folder.md](mount-folder.md#why-it-is-outside-your-home-folder).

## Can I use another folder than `/mnt/cloud`?

Yes: a simple path outside your home folder, with no spaces or special characters.
See [mount-folder.md](mount-folder.md#choosing-another-folder).

## What is the difference between a mount, an offline folder and a backup?

- A **mount** shows a whole remote as a folder. Files are fetched when you open
  them, so it needs a connection (recently used files are cached).
- An **offline folder** keeps one folder on your computer in two-way sync with a
  folder on a remote. The files are really on your disk.
- A **backup** keeps dated copies of important files: it downloads the single files you
  chose (not folders) on a schedule.

## What about Google Docs, Sheets and Slides?

They are not ordinary files. rclone shows them as converted Office files (for
example `.docx` or `.xlsx`); see rclone's notes at <https://rclone.org/drive/>. Open
and copy them through the mount as usual, but be careful putting them in an offline
folder or a backup: try it on a copy first.

## What happens when I am offline?

Mounts retry every 15 seconds until the network is back, syncs are retried by their
timer, backups by their next scheduled run. Nothing needs to be restarted. A mount
that was killed hard (say, out of memory) clears its own leftovers and starts again by
itself: [troubleshooting.md](troubleshooting.md#a-mount-stopped-working-transport-endpoint-is-not-connected).

## What does it do with my data allowance?

A mount downloads a file when you open it, and uploads what you save. An offline
folder downloads and uploads what changed. A backup downloads its listed files on
each run. Nothing else leaves or enters your computer.

## What if I move or update the plugin folder?

The installed parts are copies, so moving the plugin folder changes nothing that is
running. After updating the plugin, run the installer again or click **Update
installed parts**: [install.md](install.md#updating).

## What was it called before?

An earlier version of the plugin was called "Cloud Mounts". Its plugin id,
`io.github.rsd.cloud-mounts`, is unchanged, which is why you still see it in file
and folder names.

## How do I remove everything?

[install.md](install.md#uninstalling).

## Where is my configuration?

[reference.md](reference.md#where-everything-lives).

## Something is wrong

[troubleshooting.md](troubleshooting.md), listed by symptom.
