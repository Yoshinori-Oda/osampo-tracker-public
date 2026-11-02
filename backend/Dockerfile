FROM python:3.12-slim

COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

WORKDIR /app

# 仮想環境はソースコードの外(/opt/venv)に作る。開発中にapp/をbind mountしても仮想環境が隠れないようにするため
ENV UV_PROJECT_ENVIRONMENT=/opt/venv \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    PATH="/opt/venv/bin:$PATH" \
    PYTHONUNBUFFERED=1

# 依存パッケージを先に入れて、ソースコードだけの変更ではこの層を再利用する。
# テストもこのイメージで実行するので、devグループも入れる
COPY pyproject.toml uv.lock ./
RUN uv sync --locked

COPY . .

# アクセスログはアプリ(app/request_context.py)が出すので、uvicorn標準のものは止める
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080", "--no-access-log"]
