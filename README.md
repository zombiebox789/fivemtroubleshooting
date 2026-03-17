FiveM Troubleshooter
Automated troubleshooting script for FiveM connection, cache, and crash issues.
This script is designed to help players quickly resolve common FiveM problems without needing advanced technical knowledge.

How to Run (Recommended)
Open PowerShell and run the following command:

Gui Version
Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -Command "$p=Join-Path $env:TEMP ''InSoMNiAs-FiveM-Troubleshooter-GUI.ps1''; Remove-Item $p -Force -ErrorAction SilentlyContinue; irm ''https://raw.githubusercontent.com/zombiebox789/fivemtroubleshooting/main/InSoMNiAs-FiveM-Troubleshooter-GUI.ps1'' -OutFile $p; . $p"'

No Gui Version
Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -Command "irm ''https://raw.githubusercontent.com/zombiebox789/fivemtroubleshooting/main/FiveM-Troubleshooting.ps1'' | iex"'

This will:
• Launch PowerShell as Administrator
• Download the latest version of the script from GitHub
• Run the troubleshooter automatically

What the Troubleshooter Can Fix
The script includes automated options such as:

• Clearing FiveM cache
• Clearing crash logs
• Checking FiveM installation paths
• Exporting diagnostic logs for staff
• Checking common configuration issues
• Providing useful troubleshooting information

These fixes resolve most connection, crash, and loading issues players experience.

Use At Your Own Risk
This tool is provided as-is without any guarantees or warranties.
By running this script you acknowledge that:

• You are choosing to execute it on your system voluntarily
• The server staff and developers are not responsible for any unintended issues or system changes
• You understand the script runs with administrator privileges

The script is intended only to perform basic troubleshooting and cleanup tasks related to FiveM.

Need Additional Help?
If the troubleshooter does not resolve your issue:
Run the diagnostic export option
Upload the generated ZIP file placed on your DESKTOP
Send it to server staff for review

Server Links

Discord
https://discord.gg/pD2nFu3d

Server Rules
https://docs.google.com/document/d/16PYoLOgpm99zyC5XthGnVfzhPb8DtqEMP3cykPsx8B8

VIP Membership
https://we-the-people-rp.tebex.io/#hero
