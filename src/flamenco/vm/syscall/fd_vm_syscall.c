#include "fd_vm_syscall.h"

int
fd_vm_syscall_register( fd_sbpf_syscalls_t *   syscalls,
                        char const *           name,
                        fd_sbpf_syscall_func_t func ) {
  if( FD_UNLIKELY( (!syscalls) | (!name) ) ) return FD_VM_ERR_INVAL;

  fd_sbpf_syscalls_t * syscall = fd_sbpf_syscalls_insert( syscalls, (ulong)fd_murmur3_32( name, strlen( name ), 0U ) );
  if( FD_UNLIKELY( !syscall ) ) return FD_VM_ERR_INVAL; /* name (or hash of name) already in map */

  syscall->func = func;
  syscall->name = name;

  return FD_VM_SUCCESS;
}

int
fd_vm_syscall_register_slot( fd_sbpf_syscalls_t *      syscalls,
                             ulong                     slot,
                             fd_features_t const *     features,
                             uchar                     is_deploy ) {
  if( FD_UNLIKELY( !syscalls ) ) return FD_VM_ERR_INVAL;

  int enable_blake3_syscall                = 0;
  int enable_curve25519_syscall            = 0;
  int enable_poseidon_syscall              = 0;
  int enable_alt_bn128_syscall             = 0;
  int enable_alt_bn128_compression_syscall = 0;
  int enable_last_restart_slot_syscall     = 0;
  int enable_get_sysvar_syscall            = 0;
  int enable_get_epoch_stake_syscall       = 0;

  if( slot ) {
    enable_blake3_syscall                = FD_FEATURE_ACTIVE( slot, features, blake3_syscall_enabled );
    enable_curve25519_syscall            = FD_FEATURE_ACTIVE( slot, features, curve25519_syscall_enabled );
    enable_poseidon_syscall              = FD_FEATURE_ACTIVE( slot, features, enable_poseidon_syscall );
    enable_alt_bn128_syscall             = FD_FEATURE_ACTIVE( slot, features, enable_alt_bn128_syscall );
    enable_alt_bn128_compression_syscall = FD_FEATURE_ACTIVE( slot, features, enable_alt_bn128_compression_syscall );
    enable_last_restart_slot_syscall     = FD_FEATURE_ACTIVE( slot, features, last_restart_slot_sysvar );
    enable_get_sysvar_syscall            = FD_FEATURE_ACTIVE( slot, features, get_sysvar_syscall_enabled );
    enable_get_epoch_stake_syscall       = FD_FEATURE_ACTIVE( slot, features, enable_get_epoch_stake_syscall );

  } else { /* enable ALL */

    enable_blake3_syscall                = 1;
    enable_curve25519_syscall            = 1;
    enable_poseidon_syscall              = 1;
    enable_alt_bn128_syscall             = 1;
    enable_alt_bn128_compression_syscall = 1;
    enable_last_restart_slot_syscall     = 1;
    enable_get_sysvar_syscall            = 1;
    enable_get_epoch_stake_syscall       = 1;

  }

  fd_sbpf_syscalls_clear( syscalls );

  ulong syscall_cnt = 0UL;

# define REGISTER(name,func) do {                                                       \
    if( FD_UNLIKELY( syscall_cnt>=fd_sbpf_syscalls_key_max() ) ) return FD_VM_ERR_FULL; \
    int _err = fd_vm_syscall_register( syscalls, (name), (func) );                      \
    if( FD_UNLIKELY( _err ) ) return _err;                                              \
    syscall_cnt++;                                                                      \
  } while(0)

  /* Firedancer only (FIXME: HMMMM) */

  REGISTER( "abort",                                 fd_vm_syscall_abort );
  REGISTER( "sol_panic_",                            fd_vm_syscall_sol_panic );

  /* As of the activation of disable_deploy_of_alloc_free_syscall, which is activated on all networks,
     programs can no longer be deployed which use the sol_alloc_free_ syscall.

    https://github.com/anza-xyz/agave/blob/d6041c002bbcf1526de4e38bc18fa6e781c380e7/programs/bpf_loader/src/syscalls/mod.rs#L429 */
  if ( FD_LIKELY( !is_deploy ) ) {
    REGISTER( "sol_alloc_free_",                       fd_vm_syscall_sol_alloc_free );
  }

  /* https://github.com/solana-labs/solana/blob/v1.18.1/sdk/program/src/syscalls/definitions.rs#L39 */

  REGISTER( "sol_log_",                              fd_vm_syscall_sol_log );
  REGISTER( "sol_log_64_",                           fd_vm_syscall_sol_log_64 );
  REGISTER( "sol_log_compute_units_",                fd_vm_syscall_sol_log_compute_units );
  REGISTER( "sol_log_pubkey",                        fd_vm_syscall_sol_log_pubkey );
  REGISTER( "sol_create_program_address",            fd_vm_syscall_sol_create_program_address );
  REGISTER( "sol_try_find_program_address",          fd_vm_syscall_sol_try_find_program_address );
  REGISTER( "sol_sha256",                            fd_vm_syscall_sol_sha256 );
  REGISTER( "sol_keccak256",                         fd_vm_syscall_sol_keccak256 );
  REGISTER( "sol_secp256k1_recover",                 fd_vm_syscall_sol_secp256k1_recover );

  if( enable_blake3_syscall )
    REGISTER( "sol_blake3",                          fd_vm_syscall_sol_blake3 );

  REGISTER( "sol_get_clock_sysvar",                  fd_vm_syscall_sol_get_clock_sysvar );
  REGISTER( "sol_get_epoch_schedule_sysvar",         fd_vm_syscall_sol_get_epoch_schedule_sysvar );

  REGISTER( "sol_get_rent_sysvar",                   fd_vm_syscall_sol_get_rent_sysvar );

  if( FD_LIKELY( enable_last_restart_slot_syscall ) ) {
    REGISTER( "sol_get_last_restart_slot",           fd_vm_syscall_sol_get_last_restart_slot_sysvar );
  }

  if( enable_get_sysvar_syscall ) {
    REGISTER( "sol_get_sysvar",                      fd_vm_syscall_sol_get_sysvar );
  }

  if( enable_get_epoch_stake_syscall ) {
    REGISTER( "sol_get_epoch_stake",                 fd_vm_syscall_sol_get_epoch_stake );
  }

  REGISTER( "sol_memcpy_",                           fd_vm_syscall_sol_memcpy );
  REGISTER( "sol_memmove_",                          fd_vm_syscall_sol_memmove );
  REGISTER( "sol_memcmp_",                           fd_vm_syscall_sol_memcmp );
  REGISTER( "sol_memset_",                           fd_vm_syscall_sol_memset );
  REGISTER( "sol_invoke_signed_c",                   fd_vm_syscall_cpi_c );
  REGISTER( "sol_invoke_signed_rust",                fd_vm_syscall_cpi_rust );
  REGISTER( "sol_set_return_data",                   fd_vm_syscall_sol_set_return_data );
  REGISTER( "sol_get_return_data",                   fd_vm_syscall_sol_get_return_data );
  REGISTER( "sol_log_data",                          fd_vm_syscall_sol_log_data );
  REGISTER( "sol_get_processed_sibling_instruction", fd_vm_syscall_sol_get_processed_sibling_instruction );
  REGISTER( "sol_get_stack_height",                  fd_vm_syscall_sol_get_stack_height );
  REGISTER( "sol_get_epoch_rewards_sysvar",          fd_vm_syscall_sol_get_epoch_rewards_sysvar );

  if( enable_curve25519_syscall ) {
    REGISTER( "sol_curve_validate_point",            fd_vm_syscall_sol_curve_validate_point );
    REGISTER( "sol_curve_group_op",                  fd_vm_syscall_sol_curve_group_op );
    REGISTER( "sol_curve_multiscalar_mul",           fd_vm_syscall_sol_curve_multiscalar_mul );
  }

  // NOTE: sol_curve_pairing_map is defined but never implemented /
  // used, we can ignore it for now
//REGISTER( "sol_curve_pairing_map",                 fd_vm_syscall_sol_curve_pairing_map );

  if( enable_alt_bn128_syscall )
    REGISTER( "sol_alt_bn128_group_op",                fd_vm_syscall_sol_alt_bn128_group_op );

//REGISTER( "sol_big_mod_exp",                       fd_vm_syscall_sol_big_mod_exp );

  if( enable_poseidon_syscall )
    REGISTER( "sol_poseidon",                        fd_vm_syscall_sol_poseidon );

//REGISTER( "sol_remaining_compute_units",           fd_vm_syscall_sol_remaining_compute_units );

  if( enable_alt_bn128_compression_syscall )
    REGISTER( "sol_alt_bn128_compression",           fd_vm_syscall_sol_alt_bn128_compression );

# undef REGISTER

  return FD_VM_SUCCESS;
}
