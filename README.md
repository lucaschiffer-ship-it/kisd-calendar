# KISD Calendar

A Flutter app that helps **KISD (Köln International School of Design)** students organize their semester. It logs into Spaces, pulls your enrolled courses, and turns them into a clean timetable — with a calendar view, a list view, an integrated Spaces browser, a native TH Köln mail client, and the Mensa menu, all in one place.

> **Platform note:** Right now the app is built and tested for **iOS only**. Because Apple's build toolchain runs exclusively on macOS, you currently need a **Mac with Xcode** to compile and run it. An Android build has not been configured. See [Running without a Mac](#running-without-a-mac) below if you don't own one.

---

## Features

- **Course timetable** — scrapes your enrolled courses from Spaces and renders them as a calendar and a sortable list (My Courses / All / Favourites).
- **Spaces browser** — an in-app, already-logged-in WebView of Spaces (shared session, no second login).
- **Mail client** — native inbox for your TH Köln mailbox over IMAP/SMTP, reusing your Spaces login.
- **Mensa menu** — the daily canteen plan with prices and allergen tags.

---

## Prerequisites

You'll need the following before you start. Most of this is the standard Flutter iOS setup.

| Requirement | Notes |
|---|---|
| **macOS** | Required — the iOS toolchain only runs on Mac. |
| **Xcode** | Install the latest version from the Mac App Store, then run it once to accept the license and let it install its components. |
| **Flutter SDK** | Stable channel. Install via the [official guide](https://docs.flutter.dev/get-started/install/macos). |
| **CocoaPods** | Used for iOS native dependencies: `sudo gem install cocoapods` (or `brew install cocoapods`). |
| **An Apple device or Simulator** | An iOS Simulator (bundled with Xcode) is enough to run the app. A physical iPhone needs code signing — see below. |
| **A KISD / TH Köln account** | Your campusID and password — the app logs into Spaces and your mailbox with these. |

Verify your environment before continuing:

```bash
flutter doctor
```

Resolve anything it flags (especially the Xcode and CocoaPods rows) before moving on.

---

## Installation

1. **Clone the repository**

   ```bash
   git clone https://github.com/lucaschiffer-ship-it/kisd-calendar.git
   cd kisd-calendar
   ```

2. **Fetch Dart/Flutter dependencies**

   ```bash
   flutter pub get
   ```

3. **Install the iOS native pods**

   ```bash
   cd ios
   pod install
   cd ..
   ```

   (Flutter usually runs `pod install` for you on the first build, but doing it explicitly surfaces any CocoaPods issues early.)

---

## Running the app

### On the iOS Simulator (easiest)

1. Open a Simulator:

   ```bash
   open -a Simulator
   ```

2. From the project root, run:

   ```bash
   flutter run
   ```

   Flutter detects the booted Simulator and installs the app onto it.

### On a physical iPhone

A real device requires code signing. With a **free Apple ID** this works for personal use, but Apple expires the build after **7 days** (you just re-run to reinstall). A paid Apple Developer account removes that limit.

1. Open the iOS project in Xcode:

   ```bash
   open ios/Runner.xcworkspace
   ```

2. In the left sidebar select **Runner**, open the **Signing & Capabilities** tab, and:
   - Tick **Automatically manage signing**.
   - Under **Team**, select your Apple ID (add it via *Xcode → Settings → Accounts* if it isn't listed).
   - If Xcode complains about the bundle identifier being taken, change it to something unique (e.g. `de.kisd.kisdcalendar.yourname`).

3. Plug in your iPhone, unlock it, and trust the computer if prompted.

4. Back in the terminal, list devices and run on yours:

   ```bash
   flutter devices
   flutter run -d <your-device-id>
   ```

5. The first launch will be blocked by iOS. On the phone go to **Settings → General → VPN & Device Management**, tap your developer certificate, and **Trust** it. Then open the app again.

---

## Running without a Mac

You **cannot develop or debug** the app on iOS without a Mac — the Simulator, on-device debugging, and Xcode are all macOS-only, and that isn't going to change. But you *can* compile and install it onto an iPhone without owning one, using a cloud build service that runs real Mac hardware for you.

The practical route:

1. **Use a cloud CI/CD service** such as [Codemagic](https://codemagic.io/) (Flutter-focused, has a free tier), GitHub Actions' macOS runners, or Expo EAS. You connect this repository; the service runs Xcode in the cloud, builds, and code-signs the app.
2. **Distribute via TestFlight.** The signed build is uploaded to App Store Connect, and you install it on your iPhone through Apple's TestFlight app — no Mac involved on your end.

**The catch:** this path requires a paid **Apple Developer Program** membership (currently **99 USD/year**) for code signing and TestFlight distribution. There's no free, fully-legitimate way around that step. So a cloud build makes sense if you specifically want the app on a phone without buying a Mac — but for active development, a Mac with Xcode is by far the smoother option.

---

## First run / configuration

There's nothing to configure in code. On first launch the app asks for your **TH Köln campusID and password**, logs into Spaces, and stores the credentials in the device's secure storage (iOS Keychain). The same credentials are reused for the mail client, so you only log in once.

---

## Troubleshooting

- **`pod install` fails** — run `pod repo update` and try again; if it still fails, delete `ios/Podfile.lock` and `ios/Pods/`, then re-run.
- **"No provisioning profile" / signing errors on a device** — make sure a Team is selected in *Signing & Capabilities* and the bundle identifier is unique to you.
- **App installs but login fails** — confirm your campusID and password work directly on [spaces.kisd.de](https://spaces.kisd.de), and that you're connected to a network that can reach TH Köln services.
- **`flutter doctor` shows Xcode issues** — open Xcode once manually to finish its first-launch component install, then run `flutter doctor` again.

---

## Status

This is a personal student project, currently iOS-only and under active development. Contributions and issues are welcome.
