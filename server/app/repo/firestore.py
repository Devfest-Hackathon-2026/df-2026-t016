"""Firestore 版。トランザクションは @firestore.transactional。"""

from __future__ import annotations

from typing import Any, Callable, TypeVar

from .base import Repo, Txn

T = TypeVar("T")


class _FsTxn(Txn):
    def __init__(self, client, transaction):
        self._c = client
        self._t = transaction

    def _ref(self, col, doc_id):
        return self._c.collection(col).document(doc_id)

    def get(self, col, doc_id):
        snap = self._ref(col, doc_id).get(transaction=self._t)
        return snap.to_dict() if snap.exists else None

    def set(self, col, doc_id, data):
        self._t.set(self._ref(col, doc_id), data)

    def update(self, col, doc_id, fields):
        self._t.update(self._ref(col, doc_id), fields)

    def delete(self, col, doc_id):
        self._t.delete(self._ref(col, doc_id))


class FirestoreRepo(Repo):
    def __init__(self, project_id: str | None = None, client=None):
        if client is None:
            from google.cloud import firestore

            client = firestore.Client(project=project_id or None)
        self._c = client

    def run_txn(self, fn: Callable[[Txn], T]) -> T:
        from google.cloud import firestore

        @firestore.transactional
        def run(transaction):
            return fn(_FsTxn(self._c, transaction))

        return run(self._c.transaction())

    def get(self, col, doc_id):
        snap = self._c.collection(col).document(doc_id).get()
        return snap.to_dict() if snap.exists else None

    def query_eq(self, col: str, field: str, value: Any):
        from google.cloud.firestore_v1.base_query import FieldFilter

        q = self._c.collection(col).where(filter=FieldFilter(field, "==", value))
        return [(d.id, d.to_dict()) for d in q.stream()]
