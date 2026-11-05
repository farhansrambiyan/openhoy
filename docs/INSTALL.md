## Install

**Requirements:** macOS 15 or later on Apple silicon (M1 or later), with Messages signed in to iMessage.

1. **Download** `OpenHoy-<version>-macOS.zip` from *Assets* below and double-click it to unzip.
2. **Quit any running OpenHoy** first if you're updating: right-click an avatar in the menu bar › *Quit OpenHoy*.
3. **Move `OpenHoy.app` to your Applications folder**, replacing the old copy.
4. **Remove the download quarantine.** OpenHoy is ad-hoc signed and not notarized by Apple, so without this step macOS says the app "is damaged" or "can't be opened". Run in Terminal:
   ```sh
   xattr -dr com.apple.quarantine /Applications/OpenHoy.app
   ```
5. **Open OpenHoy.** If macOS still blocks it, go to **System Settings › Privacy & Security**, scroll down, and click **Open Anyway**.
6. **Grant permissions** in the setup window that appears:
   - **Full Disk Access** (required, to read your chats): in **System Settings › Privacy & Security › Full Disk Access**, click **+** and choose `/Applications/OpenHoy.app`, then switch it on.
   - **Messages / Automation** (required, to send): click **Allow** next to *Messages* in OpenHoy's settings, then **OK** in the macOS prompt.
   - **Contacts, Microphone, Speech Recognition, Camera, Screen Recording** (optional): allow each when you first use that feature.

### After updating
Because each build is ad-hoc signed, macOS may not recognise the new version's permissions:
- **Chats don't load:** in *Full Disk Access*, select OpenHoy, remove it with **–**, then add it again with **+**.
- **Sending fails or no Messages prompt appears:** run the command below, then click **Allow** next to *Messages* in OpenHoy's settings again:
  ```sh
  tccutil reset AppleEvents app.openhoy.OpenHoy
  ```
