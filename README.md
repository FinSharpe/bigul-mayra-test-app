# Mayra AI in the Bigul app: Flutter test app

A small Flutter app that plays the part of the Bigul app. It opens Mayra AI already signed in, through Bigul Connect's seamless bypass, with no second login. Bigul's developers can use it to test the flow and to copy the code into the Bigul app. The code is in [`lib/main.dart`](lib/main.dart).

## The URLs

| What | URL |
|---|---|
| Mayra AI (production) | `https://bigul-ai.vercel.app/` |
| In-app sign-in (load this in the WebView) | `https://bigul-ai.vercel.app/auth/mobile?next=/&n=<random>` |

The in-app sign-in URL needs two headers on the first load:

```
GET https://bigul-ai.vercel.app/auth/mobile?next=/&n=<random>
X-Bigul-Platform: 12
X-Bigul-Token: <the client's app session token>
```

Opened in a normal browser without those headers, it shows an error (`/auth/mobile/error?code=missing`). This is expected. To try Mayra in a browser, open `https://bigul-ai.vercel.app/` and sign in with Bigul.

## What the app does

1. A round Mayra button sits over the app's screen. Tapping it slides up a panel with Mayra inside.
2. On the first open, it loads `/auth/mobile` in the panel's WebView with the two headers above, behind its own loading screen. The chat appears in a few seconds, signed in.
3. Closing the panel keeps the WebView alive, so reopening is instant and the chat is where the client left it.
4. It catches `/auth/mobile/expired` (session ended, for example after 12:30 AM) and `/auth/mobile/error` (sign-in failed), and signs in again once.
5. Links to other websites open in the phone's browser.
6. Logout (top right) clears the WebView's cookies, storage and cache, as the Bigul app must on logout and account switch.

## Run it on an Android phone

You need Flutter 3.44 or later and a phone connected by USB with USB debugging on.

```bash
flutter pub get
```

```bash
flutter devices
```

```bash
flutter run -d <device-id>
```

The app points to production with platform code 12 by default. Tap the settings icon (top right), paste a fresh app session token, then tap the Mayra button.

A token lasts only until that night, so use a fresh one each test day. Paste it into the app rather than passing it with `--dart-define`, because `--dart-define` values are saved inside the build.

## What success looks like

Turn on "Show sign-in log in the panel" in settings to see each step.

- The log shows `/auth/mobile`, then `/`, then `CHAT LOADED (signed in)`.
- The chat opens signed in to the token's account, usually in about 2 seconds.
- If it fails, the log shows the error code from `/auth/mobile/error?code=...`.

## iOS

This project has only the Android folder. To try it on iOS, run `flutter create --platforms=ios .` in this folder. Then add `NSCameraUsageDescription` and `NSPhotoLibraryUsageDescription` to `ios/Runner/Info.plist`, so clients can attach images in the chat. On iOS, check that the two headers arrive on the first load.

## File uploads on Android

Clients can attach images and PDFs in the chat. In `webview_flutter` on Android, the file picker does nothing until the app implements `AndroidWebViewController.setOnShowFileSelector`. This test app doesn't implement it yet, but the Bigul app should.

## Rules for the Bigul app

- Load Mayra in the app's own WebView, never in an iframe or an external browser.
- Send the two headers on the first load only, with a GET. Never add them through a request interceptor, on redirects, or to other sites.
- Add a new random value (`n`) to the URL each time, so a reload never resends the headers.
- Never log or store the token.
- Keep the app's own loading screen up until the chat has loaded. If it hasn't loaded within 15 seconds, show the app's own error with a retry.
