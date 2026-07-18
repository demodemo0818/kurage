// Annual Reports API (Mastodon 4.6+) の HTTP 組み立て / 404 吸収のテスト。

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kurage/services/mastodon_api.dart';

void main() {
  const base = 'https://ex.com';
  const token = 'tok';
  late http.Request captured;

  void mock(String body, {int status = 200}) {
    httpClient = MockClient((req) async {
      captured = req;
      return http.Response(body, status,
          headers: {'content-type': 'application/json'});
    });
  }

  tearDown(() {
    httpClient = http.Client();
  });

  test('fetchAnnualReports は 404 を空配列で吸収する', () async {
    mock('', status: 404);
    final list = await fetchAnnualReports(instanceUrl: base, accessToken: token);
    expect(list, isEmpty);
    expect(captured.url.toString(), '$base/api/v1/annual_reports');
  });

  test('fetchAnnualReports は封筒形式をパースする', () async {
    mock(jsonEncode({
      'annual_reports': [
        {'year': 2025, 'data': {}},
      ],
      'accounts': [],
      'statuses': [],
    }));
    final list = await fetchAnnualReports(instanceUrl: base, accessToken: token);
    expect(list.single.year, 2025);
  });

  test('fetchAnnualReport は該当年を返し、未生成は null', () async {
    mock(jsonEncode({
      'annual_reports': [
        {'year': 2025, 'data': {}},
      ],
    }));
    final r = await fetchAnnualReport(
        instanceUrl: base, accessToken: token, year: 2025);
    expect(r?.year, 2025);
    expect(captured.url.toString(), '$base/api/v1/annual_reports/2025');

    mock('', status: 404);
    final none = await fetchAnnualReport(
        instanceUrl: base, accessToken: token, year: 2025);
    expect(none, isNull);
  });

  test('fetchAnnualReportState は state を拾い、404 は ineligible', () async {
    mock(jsonEncode({'state': 'generating'}));
    final s = await fetchAnnualReportState(
        instanceUrl: base, accessToken: token, year: 2025);
    expect(s, 'generating');
    expect(captured.url.toString(), '$base/api/v1/annual_reports/2025/state');

    mock('', status: 404);
    final s2 = await fetchAnnualReportState(
        instanceUrl: base, accessToken: token, year: 2025);
    expect(s2, 'ineligible');
  });

  test('generateAnnualReport は POST .../generate', () async {
    mock('', status: 200);
    await generateAnnualReport(
        instanceUrl: base, accessToken: token, year: 2025);
    expect(captured.method, 'POST');
    expect(
        captured.url.toString(), '$base/api/v1/annual_reports/2025/generate');
  });

  test('markAnnualReportRead は POST .../read', () async {
    mock('', status: 200);
    await markAnnualReportRead(
        instanceUrl: base, accessToken: token, year: 2025);
    expect(captured.method, 'POST');
    expect(captured.url.toString(), '$base/api/v1/annual_reports/2025/read');
  });
}
