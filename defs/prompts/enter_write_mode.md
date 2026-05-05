# Write Mode

You now have read-write access to the main checkout. The conversation context
above tells you what the user wants done.

## Checkpoint

**Ask yourself before any further action:** _Did the user explicitly ask me to make
this edit or run this command on the main working directory, just now?_
**Recall the user's last message.** What was the user's request? Does it explicitly
request switching to write mode, landing a change, or editing a file specifically in
the main checkout?
If the answer is "no", **stop and ask the user for confirmation first.**
Unsolicited writes risk stepping on work the user is doing in parallel.
