;; ShieldVault - Decentralized Smart Contract Protection Protocol

;; Define error constants with descriptive messages
(define-constant ERR_INVALID_SHIELD_AMOUNT (err u100))
(define-constant ERR_INSUFFICIENT_VAULT_BALANCE (err u101))
(define-constant ERR_PROTECTION_REQUEST_NOT_FOUND (err u102))
(define-constant ERR_UNAUTHORIZED_ACCESS (err u103))
(define-constant ERR_ALREADY_PROTECTED (err u104))
(define-constant ERR_INVALID_GUARDIAN (err u105))
(define-constant ERR_NO_ACTIVE_PROTECTION (err u106))
(define-constant ERR_ZERO_SHIELD_AMOUNT (err u107))
(define-constant ERR_REQUEST_ALREADY_PROCESSED (err u108))
(define-constant ERR_VAULT_DEPLETED (err u109))
(define-constant ERR_REQUEST_EXPIRED (err u110))
(define-constant ERR_SHIELD_EXCEEDS_COVERAGE (err u111))

;; Core protocol state variables
(define-data-var shield-vault-balance uint u0)
(define-data-var vault-guardian principal tx-sender)
(define-map protected-entities principal uint)
(define-map protection-requests { requester: principal, shield-amount: uint } { status: (string-ascii 25), created-at: uint, compensation: uint })

;; Protocol configuration - 30 days in blocks (assuming 10-minute block times)
(define-constant REQUEST_EXPIRATION_BLOCKS u4320)

;; Core function: Acquire protection coverage
(define-public (acquire-shield-protection (shield-amount uint))
  (let ((entity tx-sender))
    (asserts! (> shield-amount u0) ERR_ZERO_SHIELD_AMOUNT)
    (asserts! (is-none (map-get? protected-entities entity)) ERR_ALREADY_PROTECTED)
    (match (stx-transfer? shield-amount entity (as-contract tx-sender))
      success (begin
        (var-set shield-vault-balance (+ (var-get shield-vault-balance) shield-amount))
        (map-set protected-entities entity shield-amount)
        (print { event: "shield-acquired", coverage-amount: shield-amount, protected-entity: entity })
        (ok true))
      error (err error))))

;; Core function: Submit protection request
(define-public (submit-protection-request (requested-shield uint))
  (let (
    (requester tx-sender)
    (coverage-amount (default-to u0 (map-get? protected-entities requester)))
  )
    (asserts! (> requested-shield u0) ERR_ZERO_SHIELD_AMOUNT)
    (asserts! (is-some (map-get? protected-entities requester)) ERR_NO_ACTIVE_PROTECTION)
    (asserts! (>= coverage-amount requested-shield) ERR_INSUFFICIENT_VAULT_BALANCE)
    (asserts! (is-none (map-get? protection-requests { requester: requester, shield-amount: requested-shield })) ERR_REQUEST_ALREADY_PROCESSED)
    (map-set protection-requests { requester: requester, shield-amount: requested-shield } { status: "pending", created-at: block-height, compensation: u0 })
    (print { event: "protection-requested", requester: requester, requested-amount: requested-shield, timestamp: block-height })
    (ok true)))

;; Helper function: Calculate optimal compensation amount
(define-private (calculate-compensation-amount (requested-shield uint) (vault-balance uint))
  (if (>= vault-balance requested-shield)
      requested-shield
      vault-balance))

;; Guardian function: Approve protection request
(define-public (approve-protection-request (requester principal) (requested-shield uint))
  (let (
    (request-key { requester: requester, shield-amount: requested-shield })
    (request-data (unwrap! (map-get? protection-requests request-key) ERR_PROTECTION_REQUEST_NOT_FOUND))
    (vault-balance (var-get shield-vault-balance))
    (coverage-amount (unwrap! (map-get? protected-entities requester) ERR_NO_ACTIVE_PROTECTION))
  )
    (asserts! (is-eq tx-sender (var-get vault-guardian)) ERR_UNAUTHORIZED_ACCESS)
    (asserts! (is-eq (get status request-data) "pending") ERR_REQUEST_ALREADY_PROCESSED)
    (asserts! (> vault-balance u0) ERR_VAULT_DEPLETED)
    (asserts! (<= requested-shield coverage-amount) ERR_SHIELD_EXCEEDS_COVERAGE)
    (asserts! (< (- block-height (get created-at request-data)) REQUEST_EXPIRATION_BLOCKS) ERR_REQUEST_EXPIRED)
    (let ((compensation-amount (calculate-compensation-amount requested-shield vault-balance)))
      (match (as-contract (stx-transfer? compensation-amount tx-sender requester))
        success (begin
          (var-set shield-vault-balance (- vault-balance compensation-amount))
          (if (< compensation-amount requested-shield)
              (map-set protection-requests request-key { status: "partially-compensated", created-at: block-height, compensation: compensation-amount })
              (begin
                (map-delete protection-requests request-key)
                (map-delete protected-entities requester)))
          (print { event: "protection-approved", requester: requester, requested-amount: requested-shield, compensation: compensation-amount })
          (ok compensation-amount))
        error (err error)))))

;; Guardian function: Reject protection request
(define-public (reject-protection-request (requester principal) (requested-shield uint))
  (let (
    (request-key { requester: requester, shield-amount: requested-shield })
    (request-data (unwrap! (map-get? protection-requests request-key) ERR_PROTECTION_REQUEST_NOT_FOUND))
  )
    (asserts! (is-eq tx-sender (var-get vault-guardian)) ERR_UNAUTHORIZED_ACCESS)
    (asserts! (is-eq (get status request-data) "pending") ERR_REQUEST_ALREADY_PROCESSED)
    (asserts! (< (- block-height (get created-at request-data)) REQUEST_EXPIRATION_BLOCKS) ERR_REQUEST_EXPIRED)
    (map-set protection-requests request-key { status: "rejected", created-at: (get created-at request-data), compensation: u0 })
    (print { event: "protection-rejected", requester: requester, requested-amount: requested-shield })
    (ok true)))

;; Utility function: Expire stale protection requests
(define-public (expire-stale-request (requester principal) (requested-shield uint))
  (let (
    (request-key { requester: requester, shield-amount: requested-shield })
    (request-data (unwrap! (map-get? protection-requests request-key) ERR_PROTECTION_REQUEST_NOT_FOUND))
  )
    (if (and (is-eq (get status request-data) "pending")
             (>= (- block-height (get created-at request-data)) REQUEST_EXPIRATION_BLOCKS))
        (begin
          (map-set protection-requests request-key { status: "expired", created-at: (get created-at request-data), compensation: u0 })
          (print { event: "request-expired", requester: requester, requested-amount: requested-shield })
          (ok true))
        (ok false))))

;; Guardian function: Transfer guardian role
(define-public (transfer-guardian-role (new-guardian principal))
  (begin
    (asserts! (is-eq tx-sender (var-get vault-guardian)) ERR_UNAUTHORIZED_ACCESS)
    (asserts! (not (is-eq new-guardian 'SP000000000000000000002Q6VF78)) ERR_INVALID_GUARDIAN)
    (print { event: "guardian-transferred", previous-guardian: (var-get vault-guardian), new-guardian: new-guardian })
    (ok (var-set vault-guardian new-guardian))))

;; Read-only function: Get current vault balance
(define-read-only (get-vault-balance)
  (ok (var-get shield-vault-balance)))

;; Read-only function: Check if entity has active protection
(define-read-only (has-active-protection (entity principal))
  (is-some (map-get? protected-entities entity)))

;; Read-only function: Get protection coverage amount
(define-read-only (get-coverage-amount (entity principal))
  (ok (default-to u0 (map-get? protected-entities entity))))

;; Read-only function: Get protection request status
(define-read-only (get-request-status (requester principal) (requested-shield uint))
  (match (map-get? protection-requests { requester: requester, shield-amount: requested-shield })
    request-data (ok { status: (get status request-data), created-at: (get created-at request-data), compensation: (get compensation request-data) })
    ERR_PROTECTION_REQUEST_NOT_FOUND))