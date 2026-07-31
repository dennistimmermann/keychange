- **On external layout change** replaces the "Auto-disable on external switch" switch, and now
  offers four choices for what Keychange does when you change the input source yourself:
  **Disable** turns it off until you turn it back on, **Pause** turns it off and resumes on its own
  once the input source matches your keyboard again, **Ignore** keeps your choice until you switch
  keyboards, and **Reset** keeps it until your next key press.
- **Switch layout** replaces the "Intercept keystrokes" switch, choosing whether Keychange switches
  **After key press** — where the character you typed to get there still uses the previous layout —
  or **Before key press**, which fixes that character but needs Accessibility access.
- The menu bar mark now tells the two apart: a pause symbol when Keychange will resume by itself, a
  stop symbol when it is waiting for you.
- Keychange only steps aside when the new input source actually differs from the one your keyboard
  is set to. Switching to the layout it would have picked anyway no longer counts, and keyboards set
  to "Don't switch" never trigger it.
- Turning Keychange back on now applies your keyboard's input source straight away, instead of
  waiting for the next key press.
- Choosing "Before key press" no longer opens the Accessibility dialog on the spot — Keychange asks
  for access from its own panel, and only when you click.
- Keychange now stops intercepting key presses entirely while it is switched off.
- Fixed: with "Before key press", the layout sometimes did not switch when you moved to another
  keyboard.
- Both of these settings start from their defaults after updating: **Ignore**, and
  **After key press**.
