import csv
import pymysql

conn = pymysql.connect(
    host="centerbeam.proxy.rlwy.net",
    user="root",
    password="FNpMDDIVKerGZAFgoaJHalKfOmELHkQq",
    db="railway",
    port=46160,
)

cursor = conn.cursor()

with open("commonName.csv", newline='', encoding="utf-8") as f:
    reader = csv.reader(f)
    next(reader)  # skip header

    for row in reader:
        print(row)
        common_name = str(row[0])  # first column
        id = str(row[1])
        cursor.execute("""
            INSERT INTO commonAllergen (id, allergenCommonName)
            VALUES (%s,%s);
        """, (id,common_name,))

conn.commit()
cursor.close()
conn.close()