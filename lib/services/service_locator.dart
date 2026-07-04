import 'package:flutter/material.dart';
import 'login_service.dart';
import 'mail_service.dart';
import 'page_prefetcher.dart';
import 'scraper_service.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
final LoginService loginService = LoginService();
final MailService mailService = MailService();
final ScraperService scraperService = ScraperService();
final PagePrefetcher pagePrefetcher = PagePrefetcher();
