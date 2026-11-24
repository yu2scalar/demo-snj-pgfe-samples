package com.example.demo_snj_pgfe_samples.repository;

import com.example.demo_snj_pgfe_samples.exception.CustomException;
import com.example.demo_snj_pgfe_samples.model.CustomerCustomers;
import java.util.List;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowMapper;

/**
 * customer.customers with JdbcTemplate. Runs in the caller's transaction
 * (TransactionRunner). Same operations and error codes as the ScalarDB version:
 * get of a missing row 9700, update / delete of a missing row 9100.
 */
public class CustomerCustomersRepository {
    private static final String TABLE = CustomerCustomers.NAMESPACE + "." + CustomerCustomers.TABLE;
    private static final String COLUMNS = "customer_id, name, credit_limit, credit_total";
    private static final RowMapper<CustomerCustomers> ROW_MAPPER = (rs, rowNum) -> CustomerCustomers.builder()
        .customerId(rs.getInt(CustomerCustomers.CUSTOMER_ID))
        .name(rs.getString(CustomerCustomers.NAME))
        .creditLimit(rs.getLong(CustomerCustomers.CREDIT_LIMIT))
        .creditTotal(rs.getLong(CustomerCustomers.CREDIT_TOTAL))
        .build();

    private final JdbcTemplate jdbcTemplate;

    private int scanLimit = 100; // Default scan limit

    public CustomerCustomersRepository(JdbcTemplate jdbcTemplate) {
        this.jdbcTemplate = jdbcTemplate;
    }

    public void setScanLimit(int scanLimit) {
        this.scanLimit = scanLimit;
    }

    public int getScanLimit() {
        return scanLimit;
    }

    // Get Record by Primary Key
    public CustomerCustomers getCustomerCustomers(CustomerCustomers customers) {
        return getOne("SELECT " + COLUMNS + " FROM " + TABLE + " WHERE customer_id = ?", customers);
    }

    // Get Record by Primary Key and lock it until the end of the transaction
    public CustomerCustomers getCustomerCustomersForUpdate(CustomerCustomers customers) {
        return getOne("SELECT " + COLUMNS + " FROM " + TABLE + " WHERE customer_id = ? FOR UPDATE", customers);
    }

    private CustomerCustomers getOne(String sql, CustomerCustomers customers) {
        List<CustomerCustomers> result = jdbcTemplate.query(sql, ROW_MAPPER, customers.getCustomerId());
        if (result.isEmpty()) {
            throw new CustomException("No record found in CustomerCustomers", 9700);
        }
        return result.get(0);
    }

    // Insert Record (a duplicate key fails)
    public CustomerCustomers insertCustomerCustomers(CustomerCustomers customers) {
        jdbcTemplate.update("INSERT INTO " + TABLE + " (" + COLUMNS + ") VALUES (?, ?, ?, ?)",
            customers.getCustomerId(), customers.getName(), customers.getCreditLimit(), customers.getCreditTotal());
        return customers;
    }

    // Update Record (if exists)
    public CustomerCustomers updateCustomerCustomers(CustomerCustomers customers) {
        if (updateRow(customers) == 0) {
            throw new CustomException("Update condition not met: no record in CustomerCustomers", 9100);
        }
        return customers;
    }

    // Upsert Record: update, or insert if there is no such row. No ON CONFLICT / MERGE, so the
    // same SQL runs through ScalarDB Native JDBC (which refuses them) and the PostgreSQL Frontend.
    // A concurrent insert of the same key fails with a duplicate key.
    public CustomerCustomers upsertCustomerCustomers(CustomerCustomers customers) {
        if (updateRow(customers) == 0) {
            insertCustomerCustomers(customers);
        }
        return customers;
    }

    private int updateRow(CustomerCustomers customers) {
        return jdbcTemplate.update("UPDATE " + TABLE + " SET name = ?, credit_limit = ?, credit_total = ? WHERE customer_id = ?",
            customers.getName(), customers.getCreditLimit(), customers.getCreditTotal(), customers.getCustomerId());
    }

    // Delete Record (if exists)
    public void deleteCustomerCustomers(CustomerCustomers customers) {
        int rows = jdbcTemplate.update("DELETE FROM " + TABLE + " WHERE customer_id = ?", customers.getCustomerId());
        if (rows == 0) {
            throw new CustomException("Delete condition not met: no record in CustomerCustomers", 9100);
        }
    }

    // Scan All Records (up to scanLimit, no order)
    public List<CustomerCustomers> getCustomerCustomersListAll() {
        return jdbcTemplate.query("SELECT " + COLUMNS + " FROM " + TABLE + " FETCH FIRST ? ROWS ONLY",
            ROW_MAPPER, scanLimit);
    }

    // Scan Records by Primary Key
    public List<CustomerCustomers> getCustomerCustomersListByPk(CustomerCustomers customers) {
        return jdbcTemplate.query("SELECT " + COLUMNS + " FROM " + TABLE + " WHERE customer_id = ? FETCH FIRST ? ROWS ONLY",
            ROW_MAPPER, customers.getCustomerId(), scanLimit);
    }
}
