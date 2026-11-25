import os

import pymysql
from pymysql.cursors import DictCursor


def get_connection():
    return pymysql.connect(
        host=os.getenv("DB_HOST", "127.0.0.1"),
        port=int(os.getenv("DB_PORT", "3306")),
        user=os.getenv("DB_USER", "chatapp"),
        password=os.environ["DB_PASSWORD"],
        database=os.getenv("DB_NAME", "chatapp"),
        charset="utf8mb4",
        cursorclass=DictCursor,
        autocommit=False,
    )


def save_message(session_id, role, content):
    with get_connection() as connection:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                INSERT INTO messages (session_id, role, content)
                VALUES (%s, %s, %s)
                """,
                (session_id, role, content),
            )
        connection.commit()


def get_history(session_id):
    with get_connection() as connection:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                SELECT role, content, created_at
                FROM messages
                WHERE session_id = %s
                ORDER BY id ASC
                """,
                (session_id,),
            )
            return cursor.fetchall()
