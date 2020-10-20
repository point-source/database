// Copyright 2019 Gohilla Ltd.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

/// An adapter for using [Azure Cosmos DB](https://docs.microsoft.com/en-us/azure/cosmos-db/introduction),
/// a commercial cloud service by Microsoft.
library azure.cosmos_db;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:database/database.dart';
import 'package:database/database_adapter.dart';
import 'package:meta/meta.dart';
import 'package:universal_io/io.dart';

/// An adapter for using [Azure Cosmos DB](https://docs.microsoft.com/en-us/azure/cosmos-db/introduction),
/// a commercial cloud service by Microsoft.
///
/// An example:
/// ```dart
/// import 'package:database/database.dart';
///
/// void main() {
///   final database = AzureCosmosDB(
///     credentials: AzureCosmosDBCredentials(
///       apiKey: 'API KEY',
///     ),
///   );
///
///   // ...
/// }
class AzureCosmosDB extends DocumentDatabaseAdapter {
  final AzureCosmosDBCredentials _credentials;
  final HttpClient httpClient;

  AzureCosmosDB({
    @required AzureCosmosDBCredentials credentials,
    HttpClient httpClient,
  })  : assert(credentials != null),
        _credentials = credentials,
        httpClient = httpClient ??= HttpClient() {
    ArgumentError.checkNotNull(credentials, 'credentials');
  }

  @override
  Future<void> performDocumentDelete(DocumentDeleteRequest request) async {
    throw UnimplementedError();
  }

  @override
  Future<void> performDocumentInsert(DocumentInsertRequest request) async {
    final partitionKey = request.partition?.partitionId;
    final collection = request.collection;
    final collectionId = collection.collectionId;
    await _apiRequest(
        method: 'POST',
        path: '/colls/$collectionId/docs',
        partitionKey: partitionKey,
        json: request.data);
  }

  @override
  Stream<Snapshot> performDocumentRead(DocumentReadRequest request) async* {
    final document = request.document;
    final collection = document.parent;
    final collectionId = collection.collectionId;
    final partitionKey = document.partition.partitionId;
    final documentId = document.documentId;
    final response = await _apiRequest(
      method: 'GET',
      path: '/colls/$collectionId/docs/$documentId',
      partitionKey: partitionKey,
    );
    yield (Snapshot(
      document: document,
      data: response.json,
    ));
  }

  @override
  Stream<QueryResult> performDocumentSearch(
      DocumentSearchRequest request) async* {
    final query = request.query;
    final collection = request.collection;
    final collectionId = collection.collectionId;
    final queryParameters = <String, String>{};

    // filter
    {
      final filter = query.filter;
      if (filter != null) {
        queryParameters['querytype'] = 'full';
        queryParameters['search'] = filter.toString();
        queryParameters['searchmode'] = 'all';
      }
    }

    // orderBy
    {
      final sorter = query.sorter;
      if (sorter != null) {
        if (sorter is MultiSorter) {
          queryParameters['orderby'] = sorter.sorters
              .whereType<PropertySorter>()
              .map((s) => s.name)
              .join(',');
        } else if (sorter is PropertySorter) {
          queryParameters['orderby'] = sorter.name;
        }
      }
    }

    // skip
    {
      final skip = query.skip ?? 0;
      if (skip != 0) {
        queryParameters[r'$skip'] = skip.toString();
      }
    }

    // take
    {
      final take = query.take;
      if (take != null) {
        queryParameters[r'$top'] = take.toString();
      }
    }

    // Dispatch request
    final response = await _apiRequest(
      method: 'GET',
      path: '/indexes/$collectionId/docs',
      queryParameters: queryParameters,
    );

    // Return response
    final hitsJson = response.json['hits'] as Map<String, Object>;
    final hitsListJson = hitsJson['hit'] as List;
    yield (QueryResult(
      collection: collection,
      query: query,
      snapshots: List<Snapshot>.unmodifiable(hitsListJson.map((json) {
        final documentId = json['_id'] as String;
        final document = collection.document(documentId);
        final data = <String, Object>{};
        data.addAll(json);
        return Snapshot(
          document: document,
          data: data,
        );
      })),
    ));
  }

  @override
  Future<void> performDocumentUpdate(DocumentUpdateRequest request) async {
    throw UnimplementedError();
  }

  @override
  Future<void> performDocumentUpsert(DocumentUpsertRequest request) async {
    final document = request.document;
    final collection = document.parent;
    final collectionId = collection.collectionId;
    final documentId = document.documentId;
    final json = <String, Object>{};
    json.addAll(request.data);
    json['@search.action'] = 'update';
    json['_id'] = documentId;
    await _apiRequest(
      method: 'POST',
      path: '/indexes/$collectionId/docs/$documentId',
      json: json,
    );
  }

  Future<_Response> _apiRequest({
    @required String method,
    @required String path,
    String partitionKey,
    Map<String, String> queryParameters,
    Map<String, Object> json,
  }) async {
    final serviceName = _credentials.serviceId;

    path = '/dbs/$serviceName$path';

    // ?URI
    final uri = Uri(
      scheme: 'https',
      host: '$serviceName.documents.azure.com',
      path: path,
      queryParameters: queryParameters,
    );

    // RFC1123 Datetime String
    var timestamp = HttpDate.format(DateTime.now());

    var authToken = _generateAuthToken(path, method, timestamp);

    // Dispatch HTTP request
    final httpRequest = await httpClient.openUrl(method, uri);
    httpRequest.headers
        .set('Authorization', authToken, preserveHeaderCase: true);
    httpRequest.headers.set('x-ms-date', timestamp);
    httpRequest.headers.set('x-ms-version', '2018-12-31');
    if (partitionKey != null) {
      httpRequest.headers
          .set('x-ms-documentdb-partitionkey', '["$partitionKey"]');
    }
    if (json != null) {
      httpRequest.headers.contentType = ContentType.json;
      httpRequest.write(jsonEncode(json));
    }
    final httpResponse = await httpRequest.close();

    // Read HTTP response body
    final httpResponseBody = await utf8.decodeStream(httpResponse);

    // Handle error
    final statusCode = httpResponse.statusCode;
    if (statusCode != HttpStatus.ok) {
      throw AzureCosmosDBException(
        method: method,
        uri: uri,
        statusCode: statusCode,
      );
    }

    // Return response
    final response = _Response();
    response.json = jsonDecode(httpResponseBody);
    return response;
  }

  String _generateAuthToken(String path, String method, String timestamp) {
    var components = path.split('/');
    var componentCount = components.length - 1;
    String resType;
    String resLink;

    if (componentCount.isOdd) {
      resType = components[componentCount];
      var lastPart = path.lastIndexOf('/');
      resLink = path.substring(1, lastPart);
    } else {
      resType = components[componentCount - 1];
      resLink = path.substring(1);
    }

    var stringToSign = method.toLowerCase() +
        '\n' +
        resType.toLowerCase() +
        '\n' +
        resLink +
        '\n' +
        timestamp.toLowerCase() +
        '\n' +
        '' +
        '\n';

    var key = base64Decode(_credentials.apiKey);
    var signature = Hmac(sha256, key).convert(utf8.encode(stringToSign));
    var b64sig = base64Encode(signature.bytes);

    var authToken = 'type=${_credentials.keyType}&ver=1.0&sig=$b64sig';
    return authToken;
  }
}

class AzureCosmosDBCredentials {
  final String serviceId;
  final String apiKey;
  final String keyType;

  const AzureCosmosDBCredentials(
      {@required this.serviceId,
      @required this.apiKey,
      this.keyType = 'master'})
      : assert(serviceId != null),
        assert(apiKey != null),
        assert(keyType != null);

  @override
  int get hashCode => serviceId.hashCode ^ apiKey.hashCode ^ keyType.hashCode;

  @override
  bool operator ==(other) =>
      other is AzureCosmosDBCredentials &&
      serviceId == other.serviceId &&
      apiKey == other.apiKey &&
      keyType == other.keyType;
}

/// An exception thrown by [AzureCosmosDB].
class AzureCosmosDBException {
  final String method;
  final Uri uri;
  final int statusCode;

  AzureCosmosDBException({
    this.method,
    this.uri,
    this.statusCode,
  });

  @override
  String toString() => '$method $uri --> HTTP status $statusCode';
}

class _Response {
  Map<String, Object> json;
}
