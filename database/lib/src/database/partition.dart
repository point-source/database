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

import 'dart:math';

import 'package:built_value/serializer.dart';
import 'package:database/database.dart';
import 'package:database/database_adapter.dart';
import 'package:database/schema.dart';
import 'package:database/search_query_parsing.dart';
import 'package:meta/meta.dart';

/// A parition of documents in a CosmosDb collection ([Collection]).
///
///
class Partition {
  /// Returns database where the parition is.
  final Collection parentCollection;
  final Serializers serializers;
  final FullType fullType;

  /// A non-blank identifier.
  ///
  final String partitionId;

  /// Constructs a partition.
  ///
  /// Usually it's better to call the method `database.collection('colId').partition("id")`
  /// instead of this constructor.
  Partition(
    this.parentCollection,
    this.partitionId, {
    this.serializers,
    this.fullType,
  })  : assert(parentCollection != null),
        assert(partitionId != null) {
    ArgumentError.checkNotNull(parentCollection, 'parentCollection');
    if (partitionId == null || partitionId.isEmpty) {
      throw ArgumentError.value(partitionId, 'partitionId');
    }
  }

  @override
  int get hashCode => parentCollection.hashCode ^ partitionId.hashCode;

  @override
  bool operator ==(other) =>
      other is Partition &&
      partitionId == other.partitionId &&
      parentCollection == other.parentCollection;

  Database get database => parentCollection.database;

  String get collectionId => parentCollection.collectionId;

  /// Returns a document.
  ///
  /// Example:
  ///
  ///     ds.collection('exampleCollection').partition('examplePartition').document('exampleDocument').get();
  ///
  Document document(String documentId) {
    return Document(parentCollection, documentId, partition: this);
  }

  /// Inserts a new value.
  Future<Document> insert({
    Map<String, Object> data,
    Reach reach,
  }) async {
    Document result;
    await DocumentInsertRequest(
      collection: parentCollection,
      partition: this,
      document: null,
      data: data,
      reach: reach,
      onDocument: (v) {
        result = v;
      },
    ).delegateTo(database.adapter);
    return result;
  }

  /// Returns a new document with a random identifier.
  ///
  /// The current implementations generates a random 128-bit lowercase
  /// hexadecimal ID, but this is an implementation detail and could be changed
  /// in future.
  ///
  /// Example:
  ///
  ///     database.collection('example').partition('examplePartition').newDocument().insert({'key':'value'});
  ///
  // TODO: Use a more descriptive method name like documentWithRandomId()?
  Document newDocument() {
    final random = Random.secure();
    final sb = StringBuffer();
    for (var i = 0; i < 32; i++) {
      sb.write(random.nextInt(16).toRadixString(16));
    }
    return document(sb.toString());
  }

  /// Upserts ("inserts or updates") a document.
  ///
  /// Optional parameter [reach] can be used to specify the minimum level of
  /// authority needed. For example:
  ///   * [Reach.local] tells that the write only needs to reach the local
  ///     database (which may synchronized with the global database later).
  ///   * [Reach.global] tells that the write should reach the global master
  ///     database.
  Future<void> upsert({
    @required Map<String, Object> data,
    Reach reach,
  }) {
    return DocumentUpsertRequest.withData(
      collection: parentCollection,
      partition: this,
      data: data,
      reach: reach,
    ).delegateTo(database.adapter);
  }

  /// Reads schema of this collection, which may be null.
  Future<Schema> schema() async {
    final schemaResponse =
        await SchemaReadRequest.forCollection(parentCollection)
            .delegateTo(database.adapter)
            .last;
    return schemaResponse.schemasByCollection[collectionId];
  }

  /// Searches documents.
  ///
  /// This is a shorthand for taking the last item in a stream returned by
  /// [searchIncrementally].
  Future<QueryResult> search({
    Query query,
    Reach reach,
  }) {
    return searchIncrementally(
      query: query,
      reach: reach,
    ).last;
  }

  /// Deletes all documents that match the filter.
  ///
  /// Optional argument [queryString] defines a query string. The syntax is
  /// based on Lucene query syntax. For a description of the syntax, see
  /// [SearchQueryParser].
  ///
  /// Optional argument [filter] defines a filter.
  ///
  /// If both [queryString] and [filter] are non-null, the database will
  /// receive an [AndFilter] that contains both the parsed filter and the other
  /// filter.
  Future<void> searchAndDelete({
    Query query,
    Reach reach,
  }) async {
    return DocumentSearchChunkedRequest(
      collection: parentCollection,
      query: query,
      reach: reach,
    ).delegateTo(database.adapter);
  }

  /// Searches documents and returns the snapshots in chunks, which means that
  /// the snapshots don't have to be kept to the memory at the same time.
  ///
  /// Optional argument [queryString] defines a query string. The syntax is
  /// based on Lucene query syntax. For a description of the syntax, see
  /// [SearchQueryParser].
  ///
  /// Optional argument [filter] defines a filter.
  ///
  /// If both [queryString] and [filter] are non-null, the database will
  /// receive an [AndFilter] that contains both the parsed filter and the other
  /// filter.
  ///
  /// Optional argument [skip] defines how many snapshots to skip in the
  /// beginning. The default value is 0.
  ///
  /// You should usually give optional argument [take], which defines the
  /// maximum number of snapshots in the results.
  ///
  /// An example:
  ///
  ///     final stream = database.searchChunked(
  ///       query: Query.parse(
  ///         'cat OR dog',
  ///         skip: 0,
  ///         take: 1,
  ///       ),
  ///     );
  ///
  Stream<QueryResult> searchChunked({
    Query query,
    Reach reach = Reach.server,
  }) async* {
    // TODO: Real implementation
    final all = await search(
      query: query,
      reach: reach,
    );
    yield (all);
  }

  /// Searches documents and returns the result as a stream where the snapshot
  /// list incrementally grows larger.
  ///
  /// Optional argument [queryString] defines a query string. The syntax is
  /// based on Lucene query syntax. For a description of the syntax, see
  /// [SearchQueryParser].
  ///
  /// Optional argument [filter] defines a filter.
  ///
  /// If both [queryString] and [filter] are non-null, the database will
  /// receive an [AndFilter] that contains both the parsed filter and the other
  /// filter.
  ///
  /// Optional argument [skip] defines how many snapshots to skip in the
  /// beginning. The default value is 0.
  ///
  /// You should usually give optional argument [take], which defines the
  /// maximum number of snapshots in the results.
  ///
  /// An example:
  ///
  ///     final stream = database.searchIncrementally(
  ///       query: Query.parse(
  ///         'cat OR dog',
  ///         skip: 0,
  ///         take: 1,
  ///       ),
  ///     );
  ///
  Stream<QueryResult> searchIncrementally({
    Query query,
    Reach reach = Reach.server,
  }) {
    return DocumentSearchRequest(
      collection: parentCollection,
      query: query,
      reach: reach,
    ).delegateTo(database.adapter);
  }

  @override
  String toString() =>
      '$database.collection("$collectionId").partition("$partitionId")';
}
