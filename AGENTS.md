# KISD Calendar Agent Guide

## Project Overview
This is an iOS-only Flutter application for Köln International School of Design (KISD) students that integrates university course scheduling with calendar, email, and campus information systems.

## Key Commands
- `flutter pub get` - Install dependencies
- `flutter run` - Run on connected iOS device/simulator
- `flutter build ios` - Production iOS build
- `flutter analyze` - Lint/static analysis
- `flutter test` - Run tests (currently no tests exist)

## Architecture Highlights
- **Entry Point**: `lib/main.dart` initializes services and starts app
- **Service Locator**: `lib/services/service_locator.dart` provides single instances of LoginService, MailService, ScraperService  
- **Authentication**: SAML/OAuth2 login via headless InAppWebView against login.th-koeln.de and mfa.th-koeln.de
- **Scraping**: Two paths in ScraperService - fast "my courses" and slow full listing using headless WebView
- **Theme System**: Dual-layer approach with static AppTheme constants and dynamic tokens that react to theme changes

## Main Components
1. **HomeScreen** (`lib/screens/home_screen.dart`) - Tabbed interface with Mensa, Mail, List, Calendar tabs and slide-up browser overlay
2. **ListScreen** (`lib/screens/list_screen.dart`) - Course listing with filtering (my courses, favourites, all)
3. **MailScreen** (`lib/screens/mail_screen.dart`) - Gmail-style email client
4. **CalendarScreen** (`lib/screens/calendar_screen.dart`) - Device calendar integration

## Authentication Flow
- Credentials stored in FlutterSecureStorage
- Session cookies restored on app start if available
- Only runs full SAML flow if session validation fails
- MFA prompts via navigatorKey for TOTP tokens

## Data Management
- Courses cached in SharedPreferences via CacheService
- Course scraping uses headless WebView JavaScript parsing
- Device calendar writes via device_calendar package
- Email client uses enough_mail package for IMAP operations

## Theme System
- Supports light/dark/pastel themes
- Dynamic color scheme switching
- Glass effect support using BackdropFilter
- Two-layer approach: AppThemeTokens (dynamic) and AppColorScheme (static)

## Key Implementation Details
- `lib/services/scraper_service.dart` contains complex JavaScript scraping logic for course data extraction
- All services are injected via service locator pattern
- UI components use ValueListenableBuilder for responsive theming updates
- Browser overlay in HomeScreen uses AnimationController and InAppWebView integration

## Special Notes
- App is iOS-only (no Android support)
- Uses Flutter 3.11.5 with Dart 3.11.5
- Depends on flutter_inappwebview for web scraping
- Requires device calendar permissions for schedule writing