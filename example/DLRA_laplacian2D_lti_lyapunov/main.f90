program demo
   ! Standard Library
   use stdlib_optval, only : optval 
   use stdlib_linalg, only : eye, svdvals, eye
   use stdlib_math, only : all_close, logspace
   use stdlib_io_npy, only : save_npy, load_npy
   use stdlib_logger, only : information_level, warning_level, debug_level, error_level, none_level
   ! LightKrylov for linear algebra
   use LightKrylov
   use LightKrylov, only : wp => dp
   use LightKrylov_Logger
   use LightKrylov_ExpmLib
   use LightKrylov_Utils
   ! LightROM
   use LightROM_AbstractLTIsystems
   use LightROM_Utils
   use LightROM_LyapunovSolvers
   use LightROM_LyapunovUtils
   ! Laplacian
   use Laplacian2D_LTI_Lyapunov_Base
   use Laplacian2D_LTI_Lyapunov_Operators
   use Laplacian2D_LTI_Lyapunov_RKlib
   use Laplacian2D_LTI_Lyapunov_Utils
   implicit none

   character(len=128), parameter :: this_module = 'Laplacian2D_LTI_Lyapunov_Main'

   !----------------------------------------------------------
   !-----     LYAPUNOV EQUATION FOR LAPLACE OPERATOR     -----
   !----------------------------------------------------------

   ! DLRA
   integer, parameter :: rkmax = 11
   integer, parameter :: rk_X0 = 2
   ! rk_B is set in laplacian2D.f90
   integer, parameter :: irow = 8 ! how many numbers to print per row

   integer  :: nrk, ndt, rk, torder, rk0
   real(wp) :: dt, tol, Tend, Tstep
   ! vector of dt values
   real(wp), allocatable :: dtv(:)
   ! vector of rank values
   integer,  allocatable :: rkv(:)
   ! vector of tolerances
   real(wp), allocatable :: tolv(:)

   ! Exponential propagator (RKlib).
   type(rklib_lyapunov_mat), allocatable :: RK_propagator

   ! LTI system
   type(lti_system)                :: LTI
   real(wp), allocatable           :: D(:,:)
   integer                         :: p

   ! Laplacian
   type(laplace_operator), allocatable :: A

   ! LR representation
   type(LR_state)                  :: X
   type(state_vector), allocatable :: U(:)
   real(wp) , allocatable          :: S(:,:)
   
   !> STATE MATRIX (RKlib)
   type(state_matrix)              :: X_mat_RKlib(2)
   real(wp), allocatable           :: X_RKlib(:,:,:)
   real(wp), allocatable           :: X_DLRA(:,:,:)
   real(wp)                        :: X_RKlib_ref(N,N)

   ! Initial condition
   type(state_vector)              :: U0(rkmax)
   real(wp)                        :: S0(rkmax,rkmax)
   ! Matrix
   real(wp)                        :: U0_in(N,rkmax)
   real(wp)                        :: X0(N,N)

   ! OUTPUT
   real(wp)                        :: U_out(N,rkmax)
   real(wp)                        :: X_out(N,N)

   !> Information flag.
   integer                         :: info
   integer                         :: i, j, k, irep, nrep

   ! PROBLEM DEFINITION
   real(wp)  :: Adata(N,N)
   real(wp)  :: Bdata(N,N)
   real(wp)  :: BBTdata(N,N)
   
   ! LAPACK SOLUTION
   real(wp)  :: Xref(N,N)
   real(wp)  :: svals(N)

   ! timer
   integer   :: clock_rate, clock_start, clock_stop

   ! DLRA opts
   type(dlra_opts) :: opts

   call logger%configure(level=error_level, time_stamp=.false.); print *, 'Logging set to error_level.'
   
   call system_clock(count_rate=clock_rate)

   print *, '#########################################################################'
   print *, '#                                                                       #'
   print *, '#               DYNAMIC LOW-RANK APPROXIMATION  -  DLRA                 #'
   print *, '#                                                                       #'
   print *, '#########################################################################'
   print *, ''
   print *, '          LYAPUNOV EQUATION FOR THE 2D LAPLACE OPERATOR:'
   print *, ''
   print *, '                   Algebraic Lyapunov equation:'
   print *, '                     0 = A @ X + X @ A.T + Q'
   print *, ''               
   print *, '                 Differential Lyapunov equation:'
   print *, '                   \dot{X} = A @ X + X @ A.T + Q'
   print *, ''
   write(*,'(A16,I4,"x",I4)') '  Problem size: ', N, N
   print *, ''
   print *, '            Initial condition: rank(X0) =', rk_X0
   print *, '            Inhomogeneity:     rank(Q)  =', rk_B
   print *, ''
   print *, '#########################################################################'
   print *, ''

   ! Define RHS B
   do i = 1, rk_b
      call B(i)%rand(ifnorm = .false.)   
   end do
   call get_state(Bdata(:,:rk_b), B, 'Get B')
   BBTdata = matmul(Bdata(:,:rk_b), transpose(Bdata(:,:rk_b)))
   BBT(:N**2) = reshape(BBTdata, shape(BBT))

   ! Define LTI system
   LTI = lti_system()
   call LTI%initialize_lti_system(A, B, B)
   call zero_basis(LTI%CT)

   ! Define initial condition of the form X0 + U0 @ S0 @ U0.T SPD
   print '(4X,A)', 'Define initial condition.'
   print *, ''
   call generate_random_initial_condition(U0(:rk_X0), S0(:rk_X0,:rk_X0), rk_X0)
   call get_state(U_out(:,:rk_X0), U0(:rk_X0), 'Get initial condition')
   
   ! Compute the full initial condition X0 = U_in @ S0 @ U_in.T
   X0 = matmul( U_out(:,:rk_X0), matmul(S0(:rk_X0,:rk_X0), transpose(U_out(:,:rk_X0))))
   
   print *, 'SVD X0'
   svals = svdvals(X0)
   print '(1X,A16,2X*(F15.12,1X))', 'SVD(X0)[1-8]:', svals(:irow)

   
   !------------------
   ! COMPUTE EXACT SOLUTION OF THE LYAPUNOV EQUATION WITH LAPACK
   !------------------
   print *, ''
   print *, '#########################################################################'
   print *, '#                                                                       #'
   print *, '#    I.   Exact solution of the algebraic Lyapunov equation (LAPACK)    #'
   print *, '#                                                                       #'
   print *, '#########################################################################'
   print *, ''
   call system_clock(count=clock_start)     ! Start Timer
   ! Explicit 2D laplacian
   call build_operator(Adata)
   ! Solve Lyapunov equation
   call solve_lyapunov(Xref, Adata, BBTdata)
   call system_clock(count=clock_stop)      ! Stop Timer

   write(*,'(A40,F10.4," s")') '--> X_ref.    Elapsed time:', real(clock_stop-clock_start)/real(clock_rate)
   print *, ''

   ! Explicit 2D laplacian
   call build_operator(Adata)
   ! sanity check
   X0 = CALE(Xref, Adata, BBTdata)
   print '(4X,A,E15.7)', 'Direct problem: | res(X_ref) |/N = ', norm2(X0)/N
   print *, ''
   ! compute svd
   svals = svdvals(Xref)
   print '(1X,A16,2X*(F15.12,1X))', 'SVD(X_ref)[1-8]:', svals(:irow)

   !------------------
   ! COMPUTE SOLUTION WITH RK FOR DIFFERENT INTEGRATION TIMES AND COMPARE TO STUART-BARTELS
   !------------------
   print *, ''
   print *, '#########################################################################'
   print *, '#                                                                       #'
   print *, '#    IIa.  Solution using Runge-Kutta over a short time horizon         #'
   print *, '#                                                                       #'
   print *, '#########################################################################'
   print *, ''
   ! initialize exponential propagator
   nrep  = 1
   Tstep = 0.001_wp
   RK_propagator = rklib_lyapunov_mat(Tstep)
   Tend = nrep*Tstep

   allocate(X_RKlib(N, N, nrep))
   call get_state(U_out(:,:rk_X0), U0(:rk_X0), 'Get initial condition')
   X0 = matmul( U_out(:,:rk_X0), matmul(S0(:rk_X0,:rk_X0), transpose(U_out(:,:rk_X0))))
   call set_state(X_mat_RKlib(1:1), X0, 'Set RK X0')
   write(*,'(A10,A26,A26,A20)') 'RKlib:','Tend','| X_RK - X_ref |/N', 'Elapsed time'
   print *, '         ------------------------------------------------------------------------'
   do irep = 1, nrep
      call system_clock(count=clock_start)     ! Start Timer
      ! integrate
      call RK_propagator%matvec(X_mat_RKlib(1), X_mat_RKlib(2))
      ! recover output
      call get_state(X_RKlib(:,:,irep), X_mat_RKlib(2:2), 'Get RK solution')
      ! replace input
      call set_state(X_mat_RKlib(1:1), X_RKlib(:,:,irep), 'Reset RK X0')
      call system_clock(count=clock_stop)      ! Stop Timer
      write(*,'(I10,F26.4,E26.8,F18.4," s")') irep, irep*Tstep, &
                     & norm2(X_RKlib(:,:,irep) - Xref)/N, &
                     & real(clock_stop-clock_start)/real(clock_rate)
   end do

   ! Choose relevant reference case from RKlib
   X_RKlib_ref = X_RKlib(:,:,nrep)

   print *, ''
   svals = svdvals(X_RKlib_ref)
   print '(1X,A16,2X*(F15.12,1X))', 'SVD(X_RK )[1-8]:', svals(:irow)

   !------------------
   ! COMPUTE DLRA FOR SHORTEST INTEGRATION TIMES FOR DIFFERENT DT AND COMPARE WITH RK SOLUTION
   !------------------
   print *, ''
   print *, '#########################################################################'
   print *, '#                                                                       #'
   print *, '#    IIb.  Solution using fixed-rank DLRA                               #'
   print *, '#                                                                       #'
   print *, '#########################################################################'
   print *, ''
   print '(A10,A8,A4,A10,A8,3(A20),A20)', 'DLRA:','rk',' TO','dt','Tend','| X_LR - X_RK |/N', &
      & '| X_LR - X_ref |/N','| res_LR |/N', 'Elapsed time'
   write(*,'(A)', ADVANCE='NO') '         ------------------------------------------------'
   print '(A)', '--------------------------------------------------------------'
   
   ! Choose input ranks and integration steps
   rkv = [ 2, 3, 4 ]
   dtv = logspace(-6.0_wp, -3.0_wp, 4, 10)
   dtv = dtv(size(dtv):1:-1)

   allocate(X_DLRA(N, N, size(dtv)*size(rkv)*2))

   irep = 0
   X = LR_state()
   do i = 1, size(rkv)
      rk = rkv(i)
      do torder = 1, 2
         do j = 1, size(dtv)
            irep = irep + 1
            dt = dtv(j)

            ! Reset input
            call X%initialize_LR_state(U0, S0, rk)

            ! run step
            opts = dlra_opts(mode=torder, if_rank_adaptive=.false.)
            call system_clock(count=clock_start)     ! Start Timer
            call projector_splitting_DLRA_lyapunov_integrator(X, LTI%A, LTI%B, Tend, dt, info, exptA=exptA, options=opts)
            call system_clock(count=clock_stop)      ! Stop Timer

            ! Reconstruct solution
            call get_state(U_out(:,:rk), X%U, 'Reconstruct solution')
            X_out = matmul(U_out(:,:rk), matmul(X%S, transpose(U_out(:,:rk))))
            X0 = CALE(X_out, Adata, BBTdata)
            write(*,'(A10,I8," TO",I1,F10.6,F8.4,3(E20.8),F18.4," s")') 'OUTPUT', &
                              & rk, torder, dt, Tend, &
                              & norm2(X_RKlib_ref - X_out)/N, norm2(X_out - Xref)/N, &
                              & norm2(X0)/N, real(clock_stop-clock_start)/real(clock_rate)
            deallocate(X%U)
            deallocate(X%S)
            X_DLRA(:,:,irep) = X_out
         end do
         print *, ''
      end do
      print *, ''
   end do
   nrep = irep

   svals = svdvals(X_RKlib_ref)
   print '(1X,A16,2X*(F15.12,1X))', 'SVD(X_RK)[1-8]:', svals(:irow)
   svals = svdvals(X_out)
   print '(1X,A16,2X*(F15.12,1X))', 'SVD(X_LR)[1-8]:', svals(:irow)
   print *, ''
   
   deallocate(X_RKlib, X_DLRA)

   !------------------
   ! COMPUTE SOLUTION WITH RK FOR DIFFERENT INTEGRATION TIMES AND COMPARE TO STUART-BARTELS
   !------------------
   print *, ''
   print *, '#########################################################################'
   print *, '#                                                                       #'
   print *, '#    IIIa.  Solution using Runge-Kutta to steady state                  #'
   print *, '#                                                                       #'
   print *, '#########################################################################'
   print *, ''
   ! initialize exponential propagator
   nrep  = 10
   Tstep = 0.1_wp
   RK_propagator = rklib_lyapunov_mat(Tstep)
   Tend = nrep*Tstep

   allocate(X_RKlib(N, N, nrep))
   call get_state(U_out(:,:rk_X0), U0(:rk_X0), 'Get initial conditions')
   X0 = matmul( U_out(:,:rk_X0), matmul(S0(:rk_X0,:rk_X0), transpose(U_out(:,:rk_X0))))
   call set_state(X_mat_RKlib(1:1), X0, 'Set RK X0')
   write(*,'(A10,A26,A26,A20)') 'RKlib:','Tend','| X_RK - X_ref |/N', 'Elapsed time'
   print *, '         ------------------------------------------------------------------------'
   do irep = 1, nrep
      call system_clock(count=clock_start)     ! Start Timer
      ! integrate
      call RK_propagator%matvec(X_mat_RKlib(1), X_mat_RKlib(2))
      ! recover output
      call get_state(X_RKlib(:,:,irep), X_mat_RKlib(2:2), 'Get RK solution')
      ! replace input
      call set_state(X_mat_RKlib(1:1), X_RKlib(:,:,irep), 'Reset RK X0')
      call system_clock(count=clock_stop)      ! Stop Timer
      write(*,'(I10,F26.4,E26.8,F18.4," s")') irep, irep*Tstep, &
                     & norm2(X_RKlib(:,:,irep) - Xref)/N, &
                     & real(clock_stop-clock_start)/real(clock_rate)
   end do

   ! Choose relevant reference case from RKlib
   X_RKlib_ref = X_RKlib(:,:,nrep)

   print *, ''
   svals = svdvals(Xref)
   print '(1X,A16,2X*(F15.12,1X))', 'SVD(X_ref)[1-8]:', svals(:irow)
   svals = svdvals(X_RKlib_ref)
   print '(1X,A16,2X*(F15.12,1X))', 'SVD(X_RK )[1-8]:', svals(:irow)

   !------------------
   ! COMPUTE DLRA FOR SHORTEST INTEGRATION TIMES FOR DIFFERENT DT AND COMPARE WITH RK SOLUTION
   !------------------
   print *, ''
   print *, '#########################################################################'
   print *, '#                                                                       #'
   print *, '#    IIIb.  Solution using fixed-rank DLRA                              #'
   print *, '#                                                                       #'
   print *, '#########################################################################'
   print *, ''
   print '(A10,A8,A4,A10,A8,3(A20),A20)', 'DLRA:','rk',' TO','dt','Tend','| X_LR - X_RK |/N', &
      & '| X_LR - X_ref |/N','| res_LR |/N', 'Elapsed time'
   write(*,'(A)', ADVANCE='NO') '         ------------------------------------------------'
   print '(A)', '--------------------------------------------------------------'
   
   ! Choose input ranks and integration steps
   rkv = [ 4,  8 ]
   dtv = logspace(-4.0_wp, -1.0_wp, 4, 10)
   dtv = dtv(size(dtv):1:-1)

   allocate(X_DLRA(N, N, 2*size(dtv)*size(rkv)))

   irep = 0
   X = LR_state()
   do i = 1, size(rkv)
      rk = rkv(i)
      do torder = 1, 2
         do j = 1, size(dtv)
            irep = irep + 1
            dt = dtv(j)

            ! Reset input
            call X%initialize_LR_state(U0, S0, rk)

            ! run step
            opts = dlra_opts(mode=torder, if_rank_adaptive=.false.)
            call system_clock(count=clock_start)     ! Start Timer
            call projector_splitting_DLRA_lyapunov_integrator(X, LTI%A, LTI%B, Tend, dt, info, exptA=exptA, options=opts)
            call system_clock(count=clock_stop)      ! Stop Timer

            ! Reconstruct solution
            call get_state(U_out(:,:rk), X%U, 'Reconstruct solution')
            X_out = matmul(U_out(:,:rk), matmul(X%S, transpose(U_out(:,:rk))))
            X0 = CALE(X_out, Adata, BBTdata)
            write(*,'(A10,I8," TO",I1,F10.6,F8.4,3(E20.8),F18.4," s")') 'OUTPUT', &
                              & rk, torder, dt, Tend, &
                              & norm2(X_RKlib_ref - X_out)/N, norm2(X_out - Xref)/N, &
                              & norm2(X0)/N, real(clock_stop-clock_start)/real(clock_rate)
            deallocate(X%U)
            deallocate(X%S)
            X_DLRA(:,:,irep) = X_out
         end do
         print *, ''
      end do
      print *, ''
   end do

   svals = svdvals(Xref)
   print '(1X,A16,2X*(F15.12,1X))', 'SVD(X_ref)[1-8]:', svals(:irow)
   svals = svdvals(X_RKlib_ref)
   print '(1X,A16,2X*(F15.12,1X))', 'SVD(X_RK )[1-8]:', svals(:irow)
   svals = svdvals(X_out)
   print '(1X,A16,2X*(F15.12,1X))', 'SVD(X_LR )[1-8]:', svals(:irow)
   print *, ''

   deallocate(X_DLRA)

   print *, '#########################################################################'
   print *, '#                                                                       #'
   print *, '#    IIIc.  Solution using rank-adaptive DLRA                           #'
   print *, '#                                                                       #'
   print *, '#########################################################################'
   print *, ''

   ! Choose input ranks and integration step
   rk = 8 ! This is for initialisation, but the algorithm will choose the appropriate rank automatically
   dtv = logspace(-4.0_wp, -1.0_wp, 4, 10)
   dtv = dtv(size(dtv):1:-1)
   tolv = logspace(-12.0_wp, -4.0_wp, 3, 10)
   tolv = tolv(size(tolv):1:-1)
   
   allocate(X_DLRA(N, N, 2*size(dtv)*size(tolv)))

   irep = 0
   X = LR_state()
   do k = 1, size(tolv)
      tol = tolv(k)
      print '(A,E9.2)', ' SVD tol = ', tol
      print *, ''
      print '(A10,A8,A4,A10,A8,3(A20),A20)', 'DLRA:','rk_end',' TO','dt','Tend','| X_LR - X_RK |/N', &
         & '| X_LR - X_ref |/N','| res_LR |/N', 'Elapsed time'
      write(*,'(A)', ADVANCE='NO') '         ------------------------------------------------'
      print '(A)', '--------------------------------------------------------------'
      do torder = 1, 2
         do j = 1, size(dtv)
            irep = irep + 1
            dt = dtv(j)

            ! Reset input
            call X%initialize_LR_state(U0, S0, rk, rkmax, if_rank_adaptive=.true.)

            ! run step
            opts = dlra_opts(mode=torder, if_rank_adaptive=.true., tol=tol)
            call system_clock(count=clock_start)     ! Start Timer
            call projector_splitting_DLRA_lyapunov_integrator(X, LTI%A, LTI%B, Tend, dt, info, exptA=exptA, options=opts)
            call system_clock(count=clock_stop)      ! Stop Timer
            rk = X%rk

            ! Reconstruct solution
            call get_state(U_out(:,:rk), X%U(:rk), 'Reconstruct solution')
            X_out = matmul(U_out(:,:rk), matmul(X%S(:rk,:rk), transpose(U_out(:,:rk))))
            X0 = CALE(X_out, Adata, BBTdata)
            write(*,'(A10,I8," TO",I1,F10.6,F8.4,3(E20.8),F18.4," s")') 'OUTPUT', &
                                 & X%rk, torder, dt, Tend, &
                                 & norm2(X_RKlib_ref - X_out)/N, norm2(X_out - Xref)/N, &
                                 & norm2(X0)/N, real(clock_stop-clock_start)/real(clock_rate)
            deallocate(X%U)
            deallocate(X%S)
            X_DLRA(:,:,irep) = X_out
         end do
         print *, ''
      end do
      svals = svdvals(Xref)
      print '(1X,A16,2X*(F15.12,1X))', 'SVD(X_ref)[1-8]:', svals(:irow)
      svals = svdvals(X_RKlib_ref)
      print '(1X,A16,2X*(F15.12,1X))', 'SVD(X_RK )[1-8]:', svals(:irow)
      svals = svdvals(X_out)
      print '(1X,A16,2X*(F15.12,1X))', 'SVD(X_LR )[1-8]:', svals(:irow)
      print *, ''
      print *, '#########################################################################'
      print *, ''
   end do

end program demo