# MIP-B47: Accept Moonwell Ecosystem USDC Vault Ownership and Set Anthias Labs as Curator

## Summary

This proposal creates a new Moonwell Ecosystem USDC Vault (meUSDC), accepts
ownership on behalf of the temporal governor, sets Anthias Labs as the curator,
and configures a 4-day curator timelock.

## Motivation

This proposal establishes a new MetaMorpho vault for USDC as part of the
Moonwell ecosystem expansion. The vault will be managed by Anthias Labs as
curator, providing professional vault management and risk oversight with a 4-day
timelock for safety.

## Proposal Details

### Actions

1. **Deploy Moonwell Ecosystem USDC Vault**: Creates a new MetaMorpho vault
   with:

   - Name: "Moonwell Ecosystem USDC Vault"
   - Symbol: "meUSDC"
   - Asset: USDC
   - Initial Owner: Temporal Governor

2. **Accept Ownership**: The temporal governor accepts ownership of the newly
   created vault

3. **Set Curator**: Configure Anthias Labs multisig as the vault curator

4. **Set Curator Timelock**: Set the curator timelock to 4 days for additional
   security

### Technical Specifications

| Parameter        | Value                         |
| ---------------- | ----------------------------- |
| Vault Name       | Moonwell Ecosystem USDC Vault |
| Vault Symbol     | meUSDC                        |
| Asset            | USDC                          |
| Owner            | Temporal Governor             |
| Curator          | Anthias Labs Multisig         |
| Curator Timelock | 4 days                        |

## Security Considerations

- The vault ownership follows the standard Moonwell governance structure
- Anthias Labs provides experienced vault management
- The 4-day curator timelock adds an additional safety mechanism
- All changes follow established Moonwell governance processes

## Implementation

This proposal will:

1. Deploy the new meUSDC MetaMorpho vault
2. Transfer ownership to the temporal governor
3. Set Anthias Labs as curator with appropriate permissions
4. Configure the security timelock parameters
