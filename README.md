# PostgreSQL Database Engineering

## 📌 Overview

This project demonstrates practical PostgreSQL and SQL engineering through the design, implementation, testing, and optimization of an e-commerce database.

The project focuses on relational database design, advanced SQL, indexing, query optimization, data quality, transactions, analytical queries, and PostgreSQL performance analysis.

The goal is to demonstrate database engineering practices that form a strong foundation for Data Engineering.

## 🎯 Business Problem

ShopFlow is a fictional e-commerce platform that needs a reliable PostgreSQL database to manage customers, products, inventory, orders, payments, and shipments.

The database must support both operational workloads and analytical queries while maintaining data integrity and acceptable query performance.

## 🛠️ Technology Stack

* PostgreSQL
* SQL
* Python
* Docker
* Git
* GitHub

## 🔑 Key Areas

* Relational database design
* Normalization
* Primary and foreign keys
* Constraints
* Advanced SQL
* CTEs
* Window functions
* Views
* Materialized views
* Indexing
* EXPLAIN / EXPLAIN ANALYZE
* Query optimization
* Transactions
* Data quality validation
* Performance analysis

## 🚀 Getting Started

### Prerequisites

* Docker
* Docker Compose
* Git

### Start PostgreSQL

```bash
docker compose up -d
```

### Initialize the database

Run the database setup script:

```bash
./scripts/setup_database.sh
```

### Verify the database

Connect to PostgreSQL and verify the tables and sample data.

## 📊 Performance Analysis

The project includes before-and-after query performance analysis using PostgreSQL execution plans.

Performance results are based on actual benchmark runs performed against the project dataset.

## 🧪 Data Quality

The project includes SQL validation checks for:

* Duplicate records
* Null required fields
* Invalid quantities
* Invalid prices
* Orphan records
* Referential integrity

## 🎯 Project Objective

This project is part of my transition from software development and database-focused engineering into Data Engineering.

It builds on my experience with Python, PostgreSQL, SQL, database migration, and production application environments while developing deeper expertise in database engineering and analytical workloads.

## 👤 Author

Shiyam Kumar
