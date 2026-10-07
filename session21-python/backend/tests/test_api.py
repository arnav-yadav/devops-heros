import os
os.environ["DATABASE_URL"] = "sqlite:///./test.db"

from fastapi.testclient import TestClient
from app.main import app
from app.db import Base, engine
from app import models  # noqa: F401  - registers Task on Base.metadata

# The app's schema is managed by Alembic against PostgreSQL. These tests point
# at a throwaway SQLite file, where those migrations have never run, so the
# tables have to be created explicitly or every write fails with
# "no such table: tasks".
Base.metadata.create_all(bind=engine)

client = TestClient(app)

def test_health():
    assert client.get("/health").json() == {"status": "UP"}

def test_root():
    response = client.get("/")
    assert response.status_code == 200
    assert response.json()["service"] == "TaskBoard API"

def test_create_task_validation():
    response = client.post("/api/tasks", json={"title": "Deploy application", "priority": "HIGH", "assignee": "Student"})
    assert response.status_code == 201
    assert response.json()["title"] == "Deploy application"
