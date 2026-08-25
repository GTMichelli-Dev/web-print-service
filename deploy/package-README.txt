Web Print Service - Windows install package
===========================================

Prebuilt and SELF-CONTAINED. The .NET runtime is bundled, so this PC needs no
.NET install, no SDK and no git.

This service prints BasicWeigh tickets on the printers THIS PC can see. It
connects out to the web app over SignalR, so it works behind a firewall with no
inbound rules and no port forwarding.


INSTALL OR UPDATE
-----------------
Open an ADMIN command prompt in this folder and run:

    INSTALL.bat https://your-web-app-url

Use the web app's real address - the same one you type in a browser, with the
same scheme and port. A wrong URL leaves the service reconnecting forever.

The same command handles a fresh install and an update, and is safe to re-run.

    INSTALL.bat https://your-web-app-url -ServiceId scalehouse
        Name this PC on the web app's Printers page. Defaults to the computer
        name, which is usually what you want.

    INSTALL.bat https://your-web-app-url -TestPrinter "Zebra ZD421"
        Print a test page at the end, so the install is proved rather than
        assumed. The name must match one the service reports - the installer
        lists them.

    INSTALL.bat https://your-web-app-url -ResetDb
        Start from a clean database. DESTROYS the ServiceId, the ServerUrl and
        the printer settings. A timestamped backup is taken first regardless.

    powershell -ExecutionPolicy Bypass -File install.ps1 -?
        All options, including -Port and -InstallDir.


WHAT IT DOES
------------
 1. Validates the arguments, finds the binaries, and probes the web app's
    SignalR hub - a redirect or a 404 here is reported before anything is
    installed, because both leave the service reconnecting forever.
 2. Stops the service and waits for it to really stop. (It holds its own .exe;
    copying too early fails with a file lock.)
 3. Backs up the database to the Desktop, timestamped.
 4. Copies the new binaries, leaving the database alone.
 5. Writes the web app URL and the API port into appsettings.json.
 6. Checks that a silent PDF printer is installed FOR ALL USERS, and installs
    SumatraPDF via winget if not. See PRINTING below - this is the step that
    decides whether tickets actually come out.
 7. Creates the service if missing, with AUTOMATIC STARTUP and set to restart
    on failure (5s, 15s, then every 60s). An existing service has its path
    corrected and startup set to automatic.
 8. Starts it, waits for the health endpoint, and lists the printers the
    service can see - failing loudly rather than reporting success over a dead
    service.
 9. Applies the ServiceId and ServerUrl through the API, then reads them back.

The last step is not redundant: appsettings.json only seeds the database on the
first run, so on a machine that has been running for months, editing the config
file alone would change nothing.


PRINTING
--------
Tickets are PDFs, and printing one without a dialog needs a helper tool. The
service looks for, in order:

    PDFtoPrinter.exe in the install folder
    C:\Program Files\PDFtoPrinter\PDFtoPrinter.exe
    C:\Program Files\SumatraPDF\SumatraPDF.exe

ALL-USERS INSTALLS ONLY. The service runs as LocalSystem, and a normal
"winget install SumatraPDF" puts it in the installing admin's own profile,
where LocalSystem cannot see it. It then works perfectly when you double-click
a PDF and not at all from the service. The installer asks winget for
--scope machine for this reason; if that fails it says so.

Fixing it later needs no reinstall - drop PDFtoPrinter.exe into the install
folder, or install SumatraPDF for all users, and the next print finds it.

The printers themselves have the same rule. A printer added under one user's
profile - which is what happens when you add a shared \\server\printer while
logged in as yourself - is invisible to LocalSystem. Either add the printer for
all users, or set the service to log on as that user:

    services.msc -> WebPrintService -> Properties -> Log On

The installer prints the printer list it can see; if that list is empty or is
missing the ticket printer, this is why.


THE DATABASE
------------
webprintservice.db lives in the application folder and holds the ServiceId, the
ServerUrl and the printer settings. It is not part of this package - the
existing one is kept and backed up. Use -ResetDb only when you genuinely want
to start over.


AFTER INSTALLING
----------------
The installer prints the health result, the printers found and the settings it
applied. This PC's printers should appear on the web app under
Setup -> Options -> Printers.

    sc query WebPrintService
    http://localhost:5230/swagger
    http://localhost:5230/api/printers        (what the service can see)
    http://localhost:5230/api/status/health

Swagger listens on all interfaces, but Windows Firewall blocks it from other
machines unless you add an inbound rule for the port (5230 by default).


IF SOMETHING IS WRONG
---------------------
Run the service in the foreground to see the real error, rather than reading
tea leaves in the Event Log:

    net stop WebPrintService
    "C:\Services\WebPrintService\PiPrintService.exe"

Common ones:

  Service starts, no tickets print
      No all-users silent PDF printer - see PRINTING above.

  Printer list is empty
      Printers are installed per-user, service runs as LocalSystem - see
      PRINTING above.

  "Connection refused" or endless reconnecting
      The ServerUrl does not match the web app's real scheme/port. Re-run
      INSTALL.bat with the correct URL; it fixes both the config file and the
      database.

  Error 1053 on start
      An old build without Windows Service support. Update with this package.
