from typing import Optional, Annotated
from dotenv import load_dotenv, find_dotenv
from functools import lru_cache
from pydantic import field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict, NoDecode


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file='.env', 
                                      env_file_encoding='utf-8',
                                      extra='allow')

    # API Settings
    PROJECT_NAME: str = "AI Investment Analysis Sample API"
    VERSION: str = "1.0.0"
    ENVIRONMENT: str = "development"
    DEBUG: bool = True

    API_SERVER_HOST: str = "0.0.0.0"
    API_SERVER_PORT: int = 8084
    API_SERVER_WORKERS: int = 1
    LOG_LEVEL:str = "DEBUG"
    
    # CORS Settings
    ALLOW_CREDENTIALS: bool = True
    ALLOW_ORIGINS: Annotated[list[str], NoDecode] = ["*"]
    ALLOW_METHODS: Annotated[list[str], NoDecode] = ["*"]
    ALLOW_HEADERS: Annotated[list[str], NoDecode] = ["*"]

    @field_validator("ALLOW_ORIGINS", "ALLOW_METHODS", "ALLOW_HEADERS", mode="before")
    @classmethod
    def _split_csv(cls, value):
        # Accept a comma-separated string from env vars (simpler for deploy-time
        # injection) in addition to the default JSON list form.
        if isinstance(value, str) and not value.strip().startswith("["):
            return [item.strip() for item in value.split(",") if item.strip()]
        return value

    # Azure Cosmos DB Settings
    COSMOS_DB_ENDPOINT: str = ""
    COSMOS_DB_DATABASE_NAME: str = "ai-investment-analysis-sample"
    
    # Azure Blob Storage Settings
    AZURE_STORAGE_ACCOUNT_NAME: str = ""
    AZURE_STORAGE_CONTAINER_NAME: str = "opportunity-documents"

    # Azure OpenAI Settings
    AZURE_OPENAI_ENDPOINT: str = ""
    AZURE_OPENAI_DEPLOYMENT_NAME: str = ""

@lru_cache()
def get_settings() -> Settings:
    return Settings()

load_dotenv(find_dotenv('.env'))

settings: Settings = get_settings()