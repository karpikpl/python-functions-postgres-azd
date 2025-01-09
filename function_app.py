import azure.functions as func
import logging
import psycopg2
import os
from azure.storage.queue import QueueClient
from azure.identity import DefaultAzureCredential

app = func.FunctionApp(http_auth_level=func.AuthLevel.FUNCTION)

@app.route(route="httpget", methods=["GET"])
def http_get(req: func.HttpRequest) -> func.HttpResponse:
    name = req.params.get("name", "World")

    logging.info(f"Processing GET request. Name: {name}")

    return func.HttpResponse(f"Hello, {name}!")

@app.route(route="httppost", methods=["POST"])
def http_post(req: func.HttpRequest) -> func.HttpResponse:
    try:
        req_body = req.get_json()
        name = req_body.get('name')
        age = req_body.get('age')
        
        logging.info(f"Processing POST request. Name: {name}")

        if name and isinstance(name, str) and age and isinstance(age, int):
            return func.HttpResponse(f"Hello, {name}! You are {age} years old!")
        else:
            return func.HttpResponse(
                "Please provide both 'name' and 'age' in the request body.",
                status_code=400
            )
    except ValueError:
        return func.HttpResponse(
            "Invalid JSON in request body",
            status_code=400
        )


@app.timer_trigger(schedule="0 */5 * * * *", arg_name="myTimer", run_on_startup=False,
              use_monitor=False) 
def check_db_for_changes(myTimer: func.TimerRequest) -> None:
    
    if myTimer.past_due:
        logging.info('The timer is past due!')

    logging.info('Python timer trigger function executing.')
    POSTGRES_HOST = os.environ["POSTGRES_HOST"]

    POSTGRES_USERNAME = os.environ["POSTGRES_USERNAME"]
    POSTGRES_DATABASE = os.environ["POSTGRES_DATABASE"]

    if POSTGRES_HOST.endswith(".database.azure.com"):
        print("Authenticating to Azure Database for PostgreSQL using Azure Identity...")
        azure_credential = DefaultAzureCredential()
        token = azure_credential.get_token("https://ossrdbms-aad.database.windows.net/.default")
        POSTGRES_PASSWORD = token.token
    else:
        POSTGRES_PASSWORD = os.environ["POSTGRES_PASSWORD"]

    CONNECTION_STRING = f"host={POSTGRES_HOST} port=5432 dbname={POSTGRES_DATABASE} user={POSTGRES_USERNAME} password={POSTGRES_PASSWORD} sslmode=require"
    DATABASE_URI = f"postgresql://{POSTGRES_USERNAME}:{POSTGRES_PASSWORD}@{POSTGRES_HOST}/{POSTGRES_DATABASE}"
    # Specify SSL mode if needed
    if POSTGRES_SSL := os.environ.get("POSTGRES_SSL"):
        DATABASE_URI += f"?sslmode={POSTGRES_SSL}"

    with psycopg2.connect(DATABASE_URI) as connection:
        with connection.cursor() as cursor:
            cursor.execute("SELECT id, name FROM monitored_table WHERE IsProcessed = FALSE;")
            rows = cursor.fetchall()

            queue_client = QueueClient.from_connection_string(os.environ['AZURE_STORAGE_CONNECTION_STRING'], os.environ['QUEUE_NAME'])

            for row in rows:
                id, name = row
                queue_client.send_message(f"ID: {id}, Name: {name}")
                cursor.execute("UPDATE your_table SET IsProcessed = TRUE WHERE id = %s;", (id,))
            
        connection.commit()
    cursor.close()
    connection.close()


@app.queue_trigger(arg_name="azqueue", queue_name="app-queue-func-api-6oz3lgrp6b54q-x4yrgzp",
                               connection="QueueConnectionString") 
def queue_trigger(azqueue: func.QueueMessage):
    logging.info('Python Queue trigger processed a message: %s',
                azqueue.get_body().decode('utf-8'))
