# Week 5 – Local LLM Chat Application

## Overview

This project is a web-based chat application that uses a locally hosted
language model. Users can send messages and view their conversation history.

The application is deployed on a cPouta virtual machine.

**Application URL:** http://195.148.23.142/viikko5/

**GitHub repository:** https://github.com/Jebachu/viikko5-llm-chat

## Technologies

- Python and Flask
- Gunicorn
- Nginx
- MySQL
- PyMySQL
- Ollama
- qwen2.5:0.5b language model
- GitHub Actions

## Architecture

The application runs on Server A (`jebavm`).

The request flow is:

1. The browser connects to Nginx on port 80.
2. Nginx serves the application under `/viikko5/`.
3. Nginx forwards requests to Gunicorn through a Unix socket.
4. Gunicorn runs the Flask application as the `chatapp` user.
5. Flask sends requests to Ollama on `127.0.0.1:11434`.
6. Conversation messages are stored in the MySQL database named `chatapp`.

The application uses a separate Nginx configuration snippet.
Existing websites and services from earlier course weeks are preserved.

## Database and conversation history

The application uses its own MySQL database called `chatapp`.

The database user is also called `chatapp`. It has permission to read and
insert messages.

Conversation history is stored in the database. Reloading the page does
not remove existing messages. A new browser session starts a separate
conversation.

Server A uses a writable database. The read-only replica on Server B
belongs to the earlier Week 4 setup and is not used for chat message storage.

## Security

The application runs under a dedicated Linux user called `chatapp`.
This account does not have an interactive login shell.

The application environment file is:

`/etc/chatapp/chatapp.env`

It contains database credentials and application settings. It is not
stored in GitHub.

The application communicates with Ollama through localhost.
Gunicorn uses a Unix socket instead of a public network port.

GitHub Actions uses a separate SSH deployment key. The private key and
server connection details are stored as GitHub repository secrets.

## Continuous integration and deployment

The GitHub Actions workflow is located in:

`.github/workflows/ci-cd.yml`

The workflow runs tests when code is pushed to the `main` branch or
when a pull request is created for `main`.

The test job:

1. Installs Python dependencies.
2. Runs Ruff to check code quality.
3. Runs automated tests with pytest.
4. Checks the deployment script syntax.

Deployment runs only after the test job succeeds and only for pushes
to the `main` branch.

The deployment process:

1. Connects to the server using SSH.
2. Copies application files to a staging directory.
3. Installs the application and its dependencies.
4. Restarts the Week 5 application service.
5. Checks the health endpoint and deployed Git commit.

The deployment script keeps a backup of the previous application version
and can restore it if deployment fails.

The existing Nginx and systemd configuration is managed separately
and is not replaced during normal application deployments.

## Language model

The application uses the locally hosted `qwen2.5:0.5b` model through Ollama.

Ollama listens on `127.0.0.1:11434`.
The model does not require an external LLM API key.

## Testing

Automated tests are located in `test_app.py`.

The tests use mocked database and language model requests. They do not
need a running language model or a real database.

Run the checks with:

```bash
ruff check .
pytest -q
bash -n scripts/deploy.sh

Documentation verified on 2026-11-27.
