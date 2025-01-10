import azure.functions as func
import logging
import psycopg2
import os
import json
import base64
from azure.storage.queue import QueueClient
from azure.identity import DefaultAzureCredential

MONITORED_TABLE_NAME = os.environ["POSTGRES_MONITORED_TABLE_NAME"]
TARGET_TABLE_NAME = os.environ["POSTGRES_TARGET_TABLE_NAME"]

app = func.FunctionApp(http_auth_level=func.AuthLevel.FUNCTION)

@app.route(route="db/monitored", methods=["GET"])
def http_get_data_monitored(req: func.HttpRequest) -> func.HttpResponse:
    
    logging.info("Processing GET request. Reading data from DB...")
    result = get_data_from_table(MONITORED_TABLE_NAME)

    return func.HttpResponse(
        result,
        mimetype="application/json",
        headers={
            "App-Table-Name": MONITORED_TABLE_NAME
        }
    )

@app.route(route="db/target", methods=["GET"])
def http_get_data_target(req: func.HttpRequest) -> func.HttpResponse:
    
    logging.info("Processing GET request. Reading data from DB...")
    result = get_data_from_table(TARGET_TABLE_NAME)

    return func.HttpResponse(
        result,
        mimetype="application/json",
        headers={
            "App-Table-Name": TARGET_TABLE_NAME
        }
    )

@app.route(route="db/monitored", methods=["POST"])
def http_add_to_table(req: func.HttpRequest) -> func.HttpResponse:
    try:
        req_body = req.get_json()
        name = req_body.get('name')
        
        logging.info(f"Adding to table. Name: {name}")

        with get_db_connection() as connection:
            with connection.cursor() as cursor:
                cursor.execute(f"INSERT INTO {MONITORED_TABLE_NAME} (name) VALUES (%s);", (name,))
                connection.commit()

        return func.HttpResponse(
            status_code=202
        )
    except ValueError:
        return func.HttpResponse(
            "Invalid JSON in request body",
            status_code=400
        )
    except Exception as e:
        logging.error(f"Error adding to table: {e}")
        return func.HttpResponse(
            f"Error adding to table: {e}",
            status_code=500
        )
    
@app.route(route="queue", methods=["POST"])
def http_enqueue(req: func.HttpRequest) -> func.HttpResponse:
    try:
        req_body = req.get_json()
        name = req_body.get('name')
        
        logging.info(f"Adding to qeueue. Name: {name}")

        with DefaultAzureCredential() as credential:
            with QueueClient(account_url=os.environ['QUEUECONNECTION__serviceUri'], queue_name=os.environ['QUEUE_NAME'], credential=credential) as queue_client:
                encoded_message = base64.b64encode(f"From HTTP. Name: {name}".encode('utf-8')).decode('utf-8')
                queue_client.send_message(encoded_message)

        return func.HttpResponse(
            status_code=202
        )
    except ValueError:
        return func.HttpResponse(
            "Invalid JSON in request body",
            status_code=400
        )
    except Exception as e:
        logging.error(f"Error adding to queue: {e}")
        return func.HttpResponse(
            f"Error adding to queue: {e}",
            status_code=500
        )

@app.timer_trigger(schedule="0 */2 * * * *", arg_name="myTimer", run_on_startup=False,
              use_monitor=False) 
def check_db_for_changes(myTimer: func.TimerRequest) -> None:
    
    if myTimer.past_due:
        logging.info('The timer is past due!')

    logging.info('Python timer trigger function executing.')

    with get_db_connection() as connection:
        with connection.cursor() as cursor:
            cursor.execute(f"SELECT id, name FROM {MONITORED_TABLE_NAME} WHERE IsProcessed = FALSE;")
            rows = cursor.fetchall()

            credential = DefaultAzureCredential()
            queue_client = QueueClient(account_url=os.environ['QUEUECONNECTION__serviceUri'], queue_name=os.environ['QUEUE_NAME'], credential=credential)

            for row in rows:
                id, name = row
                try:
                    encoded_message = base64.b64encode(f"ID: {id}, Name: {name}".encode('utf-8')).decode('utf-8')
                    queue_client.send_message(encoded_message)
                except Exception as e:
                    logging.error(f"Error sending message to queue: {e}")

                cursor.execute(f"UPDATE {MONITORED_TABLE_NAME} SET IsProcessed = TRUE WHERE id = %s;", (id,))
            
        connection.commit()
    cursor.close()
    connection.close()


@app.queue_trigger(arg_name="azqueue", queue_name=os.environ['QUEUE_NAME'],
                               connection="QUEUECONNECTION") 
def process_message(azqueue: func.QueueMessage):

    try:
        data = azqueue.get_body().decode('utf-8')
        logging.info('Python Queue trigger processed a message: %s', data)

        new_name = data
        
        with get_db_connection() as connection:
            with connection.cursor() as cursor:
                cursor.execute(f"INSERT INTO {TARGET_TABLE_NAME} (name) VALUES (%s);", (new_name,))
                connection.commit()
    except Exception as e:
        logging.error(f"Error processing message: {e}")

def get_db_connection():
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
    
    # escape @ in the username
    POSTGRES_USERNAME = POSTGRES_USERNAME.replace('@', '%40')

    CONNECTION_STRING = f"host={POSTGRES_HOST} port=5432 dbname={POSTGRES_DATABASE} user={POSTGRES_USERNAME} password={POSTGRES_PASSWORD} sslmode=require"
    DATABASE_URI = f"postgresql://{POSTGRES_USERNAME}:{POSTGRES_PASSWORD}@{POSTGRES_HOST}:5432/{POSTGRES_DATABASE}"
    # Specify SSL mode if needed
    if POSTGRES_SSL := os.environ.get("POSTGRES_SSL"):
        DATABASE_URI += f"?sslmode={POSTGRES_SSL}"

    return psycopg2.connect(DATABASE_URI)

def get_data_from_table(table_name: str) -> str:
    try:
        result = []

        with get_db_connection() as connection:
            with connection.cursor() as cursor:
                cursor.execute(f"SELECT * FROM {table_name} ORDER BY created_date DESC")
                rows = cursor.fetchall()

                # Convert rows to a list of dictionaries
                return json.dumps(rows, default=str) 
        return result
    except Exception as e:
            error = f"Error fetching data from table {table_name}: {e}"
            logging.error(error)
            return error