"""Azure Blob Storage client factory using Managed Identity.

Primary auth is DefaultAzureCredential (user-assigned Managed Identity in ACA,
`az login` locally). A connection string is honored only as a local fallback.
"""
import logging
import os

from azure.identity import DefaultAzureCredential
from azure.storage.blob import BlobServiceClient

logger = logging.getLogger(__name__)


def get_blob_service_client(
    account_url: str = "", connection_string: str = ""
) -> BlobServiceClient:
    """Return a BlobServiceClient, preferring Managed Identity over a conn string."""
    account_url = account_url or os.getenv("STORAGE_ACCOUNT_URL", "")
    connection_string = connection_string or os.getenv("STORAGE_CONNECTION_STRING", "")

    if account_url:
        client_id = os.getenv("AZURE_CLIENT_ID")  # user-assigned MI in ACA
        credential = DefaultAzureCredential(managed_identity_client_id=client_id)
        logger.info("Connecting to Blob Storage via Managed Identity: %s", account_url)
        return BlobServiceClient(account_url=account_url, credential=credential)

    if connection_string:
        logger.warning("Connecting to Blob Storage via connection string (local fallback).")
        return BlobServiceClient.from_connection_string(connection_string)

    raise ValueError(
        "No Blob Storage credentials. Set STORAGE_ACCOUNT_URL (Managed Identity) "
        "or STORAGE_CONNECTION_STRING (local fallback)."
    )


def ensure_container(service: BlobServiceClient, name: str) -> None:
    """Create the container if it does not already exist."""
    try:
        service.create_container(name)
        logger.info("Created container: %s", name)
    except Exception:  # ResourceExistsError and benign races
        pass
