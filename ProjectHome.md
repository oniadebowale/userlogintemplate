Computer labs that use per-user home directories often require a number of setting and files be placed in the users' home directories. Apple provides some of this functionality with WorkgroupManager/MCX and home folder redirection, but this is limited and not useable in some situations.

This project attempts to go farther and provide more nuanced control of what goes into a home folder, and provide management of root and user owned folders. Folders, files, and individual entries inside plists can be controlled without affecting other plists. ByHost preferences will follow users from computer-to-computer in computer labs, and the TemporaryItems folder re-redirection common with network-home-folders is easy to setup. Additionally file names and soft-link targets can be targeted semi-dynamically.

The executable is meant to be called by a login-hook, and runs in the background  as long as the user is logged in. At log-out the program will automatically quit and clean up after itself (allowing for files that were moved aside to be put back in place).

**Status:**

The code is not yet done, but is being posted here to allow others to comment on it, or scavenge it for ideas. Most notably the code that processes plists is not yet complete, and some more thinking (and an implementation) needs to go into how to move back items that are moved aside.

Note: there are some ideas about where the project could go over on the FutureIdeas page.