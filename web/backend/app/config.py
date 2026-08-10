"""Runtime configuration (environment variables)."""
import os

SEARCH_ENDPOINT = os.getenv("SEARCH_ENDPOINT", "")
SEARCH_INDEX_NAME = os.getenv("SEARCH_INDEX_NAME", "content-index")
SEMANTIC_CONFIG = os.getenv("SEARCH_SEMANTIC_CONFIG", "semcfg")
VECTOR_FIELD = os.getenv("SEARCH_VECTOR_FIELD", "vector")

# User-assigned Managed Identity client id (set in Container Apps). None locally (az login).
AZURE_CLIENT_ID = os.getenv("AZURE_CLIENT_ID") or None

STORAGE_ACCOUNT_URL = os.getenv("STORAGE_ACCOUNT_URL", "")
SNAPSHOTS_CONTAINER = os.getenv("SNAPSHOTS_CONTAINER", "snapshots")
