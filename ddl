CREATE USER git CREATEDB;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE DATABASE gitlabhq_production OWNER git;