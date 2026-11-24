package com.example.demo_snj_pgfe_samples.service;

import com.example.demo_snj_pgfe_samples.dto.InventoryItemsDto;
import com.example.demo_snj_pgfe_samples.dto.ResponseStatusDto;
import com.example.demo_snj_pgfe_samples.exception.CustomException;
import com.example.demo_snj_pgfe_samples.mapper.InventoryItemsMapper;
import com.example.demo_snj_pgfe_samples.model.InventoryItems;
import com.example.demo_snj_pgfe_samples.repository.InventoryItemsRepository;
import java.util.List;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.stereotype.Service;

/**
 * CRUD of one table, one transaction per call with retry.
 *
 * Every call stays in one database (db_inventory), so it runs as a local transaction of that database
 * through ScalarDB Native JDBC (inventoryTx), not as a ScalarDB transaction.
 */
@Service
public class InventoryItemsService {
    private final TransactionRunner transactionRunner;
    private final InventoryItemsRepository itemsRepository;

    public InventoryItemsService(@Qualifier("inventoryTx") TransactionRunner transactionRunner,
            @Qualifier("itemsSnj") InventoryItemsRepository itemsRepository) {
        this.transactionRunner = transactionRunner;
        this.itemsRepository = itemsRepository;
    }

    // Create Record
    public ResponseStatusDto insertInventoryItems(InventoryItemsDto itemsDto) throws CustomException {
        InventoryItems items = InventoryItemsMapper.mapToInventoryItems(itemsDto);
        return transactionRunner.run(() -> {
            itemsRepository.insertInventoryItems(items);
            return ok();
        });
    }

    // Upsert Record
    public ResponseStatusDto upsertInventoryItems(InventoryItemsDto itemsDto) throws CustomException {
        InventoryItems items = InventoryItemsMapper.mapToInventoryItems(itemsDto);
        return transactionRunner.run(() -> {
            itemsRepository.upsertInventoryItems(items);
            return ok();
        });
    }

    // Retrieve Record
    public InventoryItemsDto getInventoryItems(InventoryItemsDto itemsDto) throws CustomException {
        InventoryItems items = InventoryItemsMapper.mapToInventoryItems(itemsDto);
        return transactionRunner.run(() -> InventoryItemsMapper.mapToInventoryItemsDto(itemsRepository.getInventoryItems(items)));
    }

    // Update Record
    public ResponseStatusDto updateInventoryItems(InventoryItemsDto itemsDto) throws CustomException {
        InventoryItems items = InventoryItemsMapper.mapToInventoryItems(itemsDto);
        return transactionRunner.run(() -> {
            itemsRepository.updateInventoryItems(items);
            return ok();
        });
    }

    // Delete Record
    public ResponseStatusDto deleteInventoryItems(InventoryItemsDto itemsDto) throws CustomException {
        InventoryItems items = InventoryItemsMapper.mapToInventoryItems(itemsDto);
        return transactionRunner.run(() -> {
            itemsRepository.deleteInventoryItems(items);
            return ok();
        });
    }

    // Retrieve All Records
    public List<InventoryItemsDto> getInventoryItemsListAll() throws CustomException {
        return transactionRunner.run(() -> InventoryItemsMapper.mapToInventoryItemsDtoList(itemsRepository.getInventoryItemsListAll()));
    }

    // Retrieve Records by Partition Key
    public List<InventoryItemsDto> getInventoryItemsListByPk(InventoryItemsDto itemsDto) throws CustomException {
        InventoryItems items = InventoryItemsMapper.mapToInventoryItems(itemsDto);
        return transactionRunner.run(() -> InventoryItemsMapper.mapToInventoryItemsDtoList(itemsRepository.getInventoryItemsListByPk(items)));
    }

    // AddStock: a delivery arrives - add qty to the item's stock. Only db_inventory is touched, so this is a
    // local transaction of that database through ScalarDB Native JDBC, while orders (OrderService, through
    // the PostgreSQL Frontend) may reduce the same row at the same time. The driver keeps the two
    // consistent: neither update is lost. The row is locked (FOR UPDATE) before it is read and written back.
    public InventoryItemsDto addStock(int itemId, int qty) throws CustomException {
        if (qty <= 0) {
            throw new CustomException("qty must be positive: " + qty, OrderRules.INVALID_REQUEST);
        }
        return transactionRunner.run(() -> {
            InventoryItems item = itemsRepository.getInventoryItemsForUpdate(InventoryItems.builder().itemId(itemId).build());
            item.setStock(item.getStock() + qty);
            itemsRepository.updateInventoryItems(item);
            return InventoryItemsMapper.mapToInventoryItemsDto(item);
        });
    }

    private static ResponseStatusDto ok() {
        return ResponseStatusDto.builder().code(0).message("").build();
    }
}
