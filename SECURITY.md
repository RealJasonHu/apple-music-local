# Reporting a security issue

Do not post passwords, cookies, tokens, account IDs, private queue files, or authenticated URLs in issues. For a suspected credential-handling flaw, contact the maintainer through GitHub's private vulnerability reporting feature when available; otherwise open a minimal issue requesting a private contact without exploit secrets or personal data.

The app stores a minimal download token in a restricted local file and relies on WebKit for persistent website data. It does not encrypt that file independently of the operating system. Keep account data outside source control and release archives.
