module Ginzburg_Landau_Base
   ! LightKrylov for linear algebra.
   use LightKrylov
   use LightKrylov, only: wp => dp
   use LightKrylov_Utils, only : assert_shape
   ! LightROM
   use LightROM_AbstractLTIsystems
   use LightROM_Utils   ! zero_basis for now
   ! Standard Library.
   use stdlib_math, only : linspace
   use stdlib_optval, only : optval
   use stdlib_linalg, only : eye
   implicit none

   private
   public :: nx, dx
   public :: nu, gamma, mu_0, c_mu, mu_2, mu
   public :: rk_b, x_b, s_b, rk_c, x_c, s_c
   public :: B, CT, weight, weight_mat
   public :: initialize_parameters
   public :: set_state, get_state, init_rand
   public :: N, BBTW_flat, CTCW_flat
   public :: Qc, Rinv, CTQcCW_mat, BRinvBTW_mat

   !-------------------------------
   !-----     PARAMETERS 1    -----
   !-------------------------------

   ! Mesh related parameters.
   real(wp), parameter :: L  = 50.0_wp ! Domain length
   integer,  parameter :: nx = 128     ! Number of grid points (excluding boundaries).
   real(wp)            :: dx           ! Grid size.

   !-------------------------------------------
   !-----     LIGHTKRYLOV VECTOR TYPE     -----
   !-------------------------------------------

   type, extends(abstract_vector_rdp), public :: state_vector
      real(wp) :: state(2*nx) = 0.0_wp
   contains
      private
      procedure, pass(self), public :: zero
      procedure, pass(self), public :: dot
      procedure, pass(self), public :: scal
      procedure, pass(self), public :: axpby
      procedure, pass(self), public :: rand
   end type state_vector

   !-------------------------------------------------------
   !-----     LIGHTKRYLOV SYM LOW RANK STATE TYPE     -----
   !-------------------------------------------------------

   type, extends(abstract_sym_low_rank_state_rdp), public :: LR_state
   contains
      private
      procedure, pass(self), public :: initialize_LR_state
   end type LR_state

   !-------------------------------
   !-----     PARAMETERS 2    -----
   !-------------------------------

   ! Physical parameters.
   complex(wp), parameter :: nu    = cmplx(2.0_wp, 0.2_wp, wp)
   complex(wp), parameter :: gamma = cmplx(1.0_wp, -1.0_wp, wp)
   real(wp),    parameter :: mu_0  = 0.38_wp
   real(wp),    parameter :: c_mu  = 0.2_wp
   real(wp),    parameter :: mu_2  = -0.01_wp
   real(wp)               :: mu(1:nx)

   ! Input-Output system parameters
   real(wp)               :: weight(2*nx)       ! integration weights
   integer,  parameter    :: rk_b = 2           ! number of inputs to the system
   real(wp), parameter    :: x_b = -11.0_wp     ! location of input Gaussian
   real(wp), parameter    :: s_b = 1.0_wp       ! variance of input Gaussian
   type(state_vector)     :: B(rk_b)
   real(wp), parameter    :: x_c = sqrt(-2.0_wp*(mu_0 - c_mu**2)/mu_2) ! location of input Gaussian
   real(wp), parameter    :: s_c = 1.0_wp       ! variance of input Gaussian
   integer,  parameter    :: rk_c = 2           ! number of outputs to the system
   type(state_vector)     :: CT(rk_c)
   real(wp)               :: Qc(rk_c,rk_c)
   real(wp)               :: Rinv(rk_b,rk_b)

   ! Data matrices for RK lyap
   integer,  parameter    :: N = 2*nx           ! Number of grid points (excluding boundaries).
   real(wp)               :: weight_mat(N**2)   ! integration weights
   real(wp)               :: BBTW_flat(N**2)
   real(wp)               :: CTCW_flat(N**2)
   ! Data matrices for Riccatis
   real(wp)               :: CTQcCW_mat(N,N)
   real(wp)               :: BRinvBTW_mat(N,N)

contains

   !--------------------------------------------------------------
   !-----     CONSTRUCT THE MESH AND PHYSICAL PARAMETERS     -----
   !--------------------------------------------------------------

   subroutine initialize_parameters()
      implicit none
      ! Mesh array.
      real(wp), allocatable :: x(:)
      real(wp)              :: x2(1:2*nx)
      real(wp)              :: tmpv(N, 2)
      integer               :: i

      ! Construct mesh.
      x = linspace(-L/2, L/2, nx+2)
      dx = x(2)-x(1)

      ! Construct mu(x)
      mu(:) = (mu_0 - c_mu**2) + (mu_2 / 2.0_wp) * x(2:nx+1)**2

      ! Define integration weights
      weight     = dx
      weight_mat = dx

      ! Construct B & C
      ! B = [ [ Br, -Bi ], [ Bi, Br ] ]
      ! B = [ [ Cr, -Ci ], [ Ci, Cr ] ]
      ! where Bi = Ci = 0

      ! actuator is a Guassian centered just upstream of branch I
      ! column 1
      x2       = 0.0_wp
      x2(1:nx) = x(2:nx+1)
      B(1)%state = 0.5*exp(-((x2 - x_b)/s_b)**2)*sqrt(weight)
      ! column 2
      x2            = 0.0_wp
      x2(nx+1:2*nx) = x(2:nx+1)
      B(2)%state = 0.5*exp(-((x2 - x_b)/s_b)**2)*sqrt(weight)

      ! the sensor is a Gaussian centered at branch II
      ! column 1
      x2       = 0.0_wp
      x2(1:nx) = x(2:nx+1)
      CT(1)%state = 0.5*exp(-((x2 - x_c)/s_c)**2)*sqrt(weight)
      ! column 2
      x2            = 0.0_wp
      x2(nx+1:2*nx) = x(2:nx+1)
      CT(2)%state = 0.5*exp(-((x2 - x_c)/s_c)**2)*sqrt(weight)

      ! Note that we have included the integration weights into the actuator/sensor definitions

      ! RK lyap & riccati
      Qc   = eye(rk_c)
      Rinv = eye(rk_b)
      tmpv = 0.0_wp
      call get_state(tmpv(:,1:rk_b), B(1:rk_b))
      BBTW_flat(1:N**2)     = reshape(matmul(tmpv, transpose(tmpv)), shape(BBTW_flat))
      BRinvBTW_mat(1:N,1:N) = matmul(matmul(tmpv, Rinv), transpose(tmpv))
      call get_state(tmpv(:,1:rk_c), CT(1:rk_c))
      CTCW_flat(1:N**2)     = reshape(matmul(tmpv, transpose(tmpv)), shape(CTCW_flat))
      CTQcCW_mat(1:N,1:N)   = matmul(matmul(tmpv, Qc), transpose(tmpv))

      return
   end subroutine initialize_parameters

   !=========================================================
   !=========================================================
   !=====                                               =====
   !=====     LIGHTKRYLOV MANDATORY IMPLEMENTATIONS     =====
   !=====                                               =====
   !=========================================================
   !=========================================================

   !----------------------------------------------------
   !-----     TYPE-BOUND PROCEDURE FOR VECTORS     -----
   !----------------------------------------------------

   subroutine zero(self)
      class(state_vector), intent(inout) :: self
      self%state = 0.0_wp
      return
   end subroutine zero

   real(wp) function dot(self, vec) result(alpha)
      ! weighted inner product
      class(state_vector),        intent(in) :: self
      class(abstract_vector_rdp), intent(in) :: vec
      select type(vec)
      type is(state_vector)
         alpha = dot_product(self%state, weight*vec%state)
      end select
      return
   end function dot

   subroutine scal(self, alpha)
      class(state_vector), intent(inout) :: self
      real(wp),            intent(in)    :: alpha
      self%state = self%state * alpha
      return
   end subroutine scal

   subroutine axpby(self, alpha, vec, beta)
      class(state_vector),        intent(inout) :: self
      class(abstract_vector_rdp), intent(in)    :: vec
      real(wp),                   intent(in)    :: alpha, beta
      select type(vec)
      type is(state_vector)
         self%state = alpha*self%state + beta*vec%state
      end select
      return
   end subroutine axpby

   subroutine rand(self, ifnorm)
      class(state_vector), intent(inout) :: self
      logical, optional,   intent(in)    :: ifnorm
      ! internals
      logical :: normalize
      real(wp) :: alpha
      normalize = optval(ifnorm,.true.)
      call random_number(self%state)
      if (normalize) then
         alpha = self%norm()
         call self%scal(1.0/alpha)
      endif
      return
   end subroutine rand

   !----------------------------------------------
   !-----     UTILITIES FOR STATE_VECTORS    -----
   !----------------------------------------------

   subroutine get_state(mat_out, state_in)
      !! Utility function to transfer data from a state vector to a real array
      real(wp),                   intent(out) :: mat_out(:,:)
      class(abstract_vector_rdp), intent(in)  :: state_in(:)
      ! internal variables
      integer :: k, kdim
      mat_out = 0.0_wp
      select type (state_in)
      type is (state_vector)
         kdim = size(state_in)
         call assert_shape(mat_out, (/ 2*nx, kdim /), 'get_state -> state_vector', 'mat_out')
         do k = 1, kdim
            mat_out(:,k) = state_in(k)%state
         end do
      end select
      return
   end subroutine get_state

   subroutine set_state(state_out, mat_in)
      !! Utility function to transfer data from a real array to a state vector
      class(abstract_vector_rdp), intent(out) :: state_out(:)
      real(wp),                   intent(in)  :: mat_in(:,:)
      ! internal variables
      integer       :: k, kdim
      select type (state_out)
      type is (state_vector)
         kdim = size(state_out)
         call assert_shape(mat_in, (/ 2*nx, kdim /), 'set_state -> state_vector', 'mat_in')
         call zero_basis(state_out)
         do k = 1, kdim
            state_out(k)%state = mat_in(:,k)
         end do
      end select
      return
   end subroutine set_state

   subroutine init_rand(state, ifnorm)
      !! Utility function to initialize a state vector with random data
      class(abstract_vector_rdp), intent(inout)  :: state(:)
      logical, optional,          intent(in)     :: ifnorm
      ! internal variables
      integer :: k, kdim
      logical :: normalize
      normalize = optval(ifnorm,.true.)
      select type (state)
      type is (state_vector)
         kdim = size(state)
         do k = 1, kdim
            call state(k)%rand(ifnorm = normalize)
         end do
      end select
      return
   end subroutine init_rand

   !------------------------------------------------------
   !-----     TYPE BOUND PROCEDURES FOR LR STATES    -----
   !------------------------------------------------------

   subroutine initialize_LR_state(self, U, S, rk)
      class(LR_state),            intent(inout) :: self
      class(abstract_vector_rdp), intent(in)    :: U(:)
      real(wp),                   intent(in)    :: S(:,:)
      integer,                    intent(in)    :: rk

      if (rk > size(U)) then
         write(*,*) 'Input state rank is lower than the chosen rank! Abort.'
         STOP 1
         ! this could be improved by initialising extra columns with random vectors
         ! orthonormalize these against the existing columns of U and set the corresponding
         ! entries in S to 0.
      end if

      select type (U)
      type is (state_vector)
         allocate(self%U(1:rk), source=U(1:rk))
         allocate(self%S(1:rk,1:rk)); 
         self%S(1:rk,1:rk) = S(1:rk,1:rk) 
      end select
      return
   end subroutine initialize_LR_state

end module Ginzburg_Landau_Base
