# Security policy

## Reporting a vulnerability

Mail **info@keychange.dev**. Please do not open a public issue for something that could be
exploited before there is a fix.

Say what the problem is and how to reproduce it; a rough proof of concept helps more than a
polished one. You will get a reply within a week — if you do not, assume the mail went astray
and send it again.

Keychange is one person's free app, so there is no bounty and no guaranteed timeline. What there
is: the report gets read, the fix ships in the next release, and you are credited unless you
would rather not be.

## Scope

Only the latest release is supported. Sparkle updates in place, so anything older is fixed by
updating.

Keychange asks for Input Monitoring, which means it sees every key event on the machine. Reports
that matter most:

- Key events leaving the process — written to disk, logged, or sent anywhere.
- Anything that lets another process read them through Keychange.
- The update path: a way to make Sparkle install a build that is not the Developer ID signed
  release it validates against.
- Gaining privileges or access beyond the permissions the app asks for.

Out of scope: that Keychange needs Input Monitoring at all — it cannot tell which keyboard
produced a key event without it — and anything that assumes the attacker already runs code as
your user, since at that point they can watch the keyboard themselves.
